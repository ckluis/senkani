import Foundation

/// V.13b-4c — synchronous dispatch helper that the serve-path chatHandler
/// closure calls for `.quick/.balanced/.frontier` requests. Implements the
/// b-2b safety bundle:
///   - runs `ClaudeAPIChatEngine.chat(...)` OFF the listener thread via
///     `ServeBridge.runBlocking` (the engine is already configured with
///     `RetryPolicy.serveSafe` + per-request `URLRequest.timeoutInterval`
///     by `ClaudeAPIServeEngineFactory.make(...)`);
///   - NEVER wraps the call in `MLXInferenceLock.shared` — that's a
///     Gemma/Metal lock; a rate-limited Claude request only blocks its
///     own NWListener connection thread, and the lock would falsely
///     serialize independent network requests across the process;
///   - catches the TYPED `ClaudeAPIChatEngineError` (no `try?` swallow)
///     and maps to (httpStatus, wire bytes) via the static mapper at
///     `ClaudeAPIChatEngine.openAIWireResponse(_:)`;
///   - builds the matching `AuditFields` for ServeCommand's single
///     `OpenAIServedRequestSink.record(...)` call (one row per request,
///     real httpStatus across success / 429 / 502 / 400 branches).
///
/// All work in this enum is pure-sync; no actor hops, no shared mutable
/// state. The Anthropic key is held in the engine instance only — this
/// helper never sees the raw key, only the `keyLabel` for the audit row.
public enum ClaudeAPIServeDispatch {

    /// Outcome of one non-local-tier dispatch through the Claude engine.
    /// The caller (ServeCommand chatHandler closure) records exactly one
    /// audit row using `auditFields` + `httpStatus`, optionally with the
    /// opt-in `auditBodies` when `--audit-bodies` is on, and returns
    /// `data` as the wire response.
    public struct Outcome: Sendable {
        public let httpStatus: Int
        public let data: Data
        public let auditFields: OpenAIAuditChain.AuditFields
        public let auditBodies: OpenAIAuditChain.AuditBodies?

        public init(
            httpStatus: Int,
            data: Data,
            auditFields: OpenAIAuditChain.AuditFields,
            auditBodies: OpenAIAuditChain.AuditBodies?
        ) {
            self.httpStatus = httpStatus
            self.data = data
            self.auditFields = auditFields
            self.auditBodies = auditBodies
        }
    }

    /// Dispatch a single non-local-tier chat request through the Claude
    /// engine. Routing is precomputed by the caller (already-resolved tier
    /// + `actualModel`). `id` is the pre-allocated `chatcmpl-…` id used for
    /// both the response and any audit body.
    public static func dispatch(
        engine: ClaudeAPIChatEngine,
        request: ChatCompletionRequest,
        routing: OpenAIChatHandler.Routing,
        keyLabel: String?,
        now: Date,
        id: String
    ) -> Outcome {
        // Build the heuristic prompt-token count up front — it's used for
        // BOTH the success path and any error audit row (no completion
        // bytes in the error case, so completionTokenCount is 0).
        let promptText = request.messages.map(\.content).joined(separator: "\n")
        let promptTokens = OpenAIChatHandler.estimateTokens(promptText)
        let model = routing.actualModel
        let messages = request.messages
        let tools = request.tools ?? []

        // Bridge async → sync OFF the listener thread (b-2b safety bundle).
        // We capture EITHER a successful Completion OR the typed error;
        // the closure cannot throw across the boundary, so we union them.
        enum Captured: Sendable {
            case success(OpenAIChatHandler.Completion)
            case engineError(ClaudeAPIChatEngineError)
            case cancellation
            case other(String)
        }
        let captured: Captured = ServeBridge.runBlocking {
            do {
                let completion = try await engine.chat(
                    model: model, messages: messages, tools: tools
                )
                return Captured.success(completion)
            } catch let e as ClaudeAPIChatEngineError {
                return Captured.engineError(e)
            } catch is CancellationError {
                return Captured.cancellation
            } catch {
                // Anything else collapses to a fixed sentinel — never
                // `String(describing:)` (Schneier info-leak guard).
                return Captured.other("unknown-error")
            }
        }

        switch captured {
        case .success(let completion):
            return successOutcome(
                completion: completion,
                request: request,
                routing: routing,
                keyLabel: keyLabel,
                now: now,
                id: id
            )
        case .engineError(let err):
            return errorOutcome(
                error: err,
                request: request,
                routing: routing,
                keyLabel: keyLabel,
                now: now,
                promptTokens: promptTokens
            )
        case .cancellation:
            // Listener-thread cancellation surfaces the same shape as a
            // generic network error so the wire contract is uniform.
            return errorOutcome(
                error: .networkError(code: -999),
                request: request,
                routing: routing,
                keyLabel: keyLabel,
                now: now,
                promptTokens: promptTokens
            )
        case .other:
            return errorOutcome(
                error: .networkError(code: -1),
                request: request,
                routing: routing,
                keyLabel: keyLabel,
                now: now,
                promptTokens: promptTokens
            )
        }
    }

    // MARK: - Success path

    private static func successOutcome(
        completion: OpenAIChatHandler.Completion,
        request: ChatCompletionRequest,
        routing: OpenAIChatHandler.Routing,
        keyLabel: String?,
        now: Date,
        id: String
    ) -> Outcome {
        let usesTools = !completion.toolCalls.isEmpty
        let choiceMessage: ChatCompletionResponse.Choice.Message = usesTools
            ? .init(role: "assistant", content: nil, toolCalls: completion.toolCalls)
            : .init(role: "assistant", content: completion.content)
        let finishReason = usesTools ? "tool_calls" : "stop"

        let resolvedPromptTokens = completion.realPromptTokens ?? completion.promptTokens
        let resolvedCompletionTokens = completion.realCompletionTokens ?? completion.completionTokens

        let response = ChatCompletionResponse(
            id: id,
            created: Int(now.timeIntervalSince1970),
            model: routing.actualModel,
            choices: [
                .init(index: 0, message: choiceMessage, finishReason: finishReason)
            ],
            usage: .init(
                promptTokens: resolvedPromptTokens,
                completionTokens: resolvedCompletionTokens,
                totalTokens: resolvedPromptTokens + resolvedCompletionTokens
            )
        )

        let fields = OpenAIAuditChain.AuditFields(
            ts: now,
            keyLabel: keyLabel,
            surface: "chat",
            modelLogged: routing.modelLogged,
            presetUsed: routing.presetUsed.rawValue,
            resolvedTier: routing.resolvedTier.rawValue,
            promptTokenCount: resolvedPromptTokens,
            completionTokenCount: resolvedCompletionTokens,
            status: "ok"
        )
        let responseBody = usesTools
            ? "tool_calls=[" + completion.toolCalls.map(\.function.name).joined(separator: ",") + "]"
            : completion.content
        let bodies = OpenAIAuditChain.AuditBodies(
            requestBody: OpenAIChatHandler.requestSummary(request),
            responseBody: responseBody
        )
        return Outcome(
            httpStatus: 200,
            data: OpenAIChatHandler.encodeResponse(response),
            auditFields: fields,
            auditBodies: bodies
        )
    }

    // MARK: - Error path

    private static func errorOutcome(
        error: ClaudeAPIChatEngineError,
        request: ChatCompletionRequest,
        routing: OpenAIChatHandler.Routing,
        keyLabel: String?,
        now: Date,
        promptTokens: Int
    ) -> Outcome {
        let mapped = ClaudeAPIChatEngine.openAIWireResponse(error)
        // Lauret re-audit FOLD: 401 → `upstream_auth_error` audit token to
        // match the wire `error.code`, so an operator querying the persisted
        // request log can distinguish auth failures from other upstream 502s
        // without reparsing wire bytes.
        let statusToken: String
        switch error {
        case .rateLimited:                statusToken = "upstream_rate_limited"
        case .upstreamError(let status, _) where status == 401:
                                          statusToken = "upstream_auth_error"
        case .upstreamError:              statusToken = "upstream_error"
        case .decodeError:                statusToken = "upstream_decode_error"
        case .networkError:               statusToken = "upstream_network_error"
        case .upstreamModelUnavailable:   statusToken = "model_not_found"
        }
        let fields = OpenAIAuditChain.AuditFields(
            ts: now,
            keyLabel: keyLabel,
            surface: "chat",
            modelLogged: routing.modelLogged,
            presetUsed: routing.presetUsed.rawValue,
            resolvedTier: routing.resolvedTier.rawValue,
            promptTokenCount: promptTokens,
            completionTokenCount: 0,
            status: statusToken
        )
        let bodies = OpenAIAuditChain.AuditBodies(
            requestBody: OpenAIChatHandler.requestSummary(request),
            responseBody: "[error: \(statusToken)]"
        )
        return Outcome(
            httpStatus: mapped.httpStatus,
            data: mapped.data,
            auditFields: fields,
            auditBodies: bodies
        )
    }

    /// V.13b-4c — `stream:true` non-local-tier rendering. The listener
    /// closure detects the case + asks for this complete framed 501; no
    /// SSE byte is sent. ServeCommand records one audit row with the
    /// returned fields + httpStatus 501.
    public static func streamNotSupportedOutcome(
        request: ChatCompletionRequest,
        routing: OpenAIChatHandler.Routing,
        keyLabel: String?,
        now: Date
    ) -> Outcome {
        let promptText = request.messages.map(\.content).joined(separator: "\n")
        let promptTokens = OpenAIChatHandler.estimateTokens(promptText)
        let data = OpenAIChatHandler.errorResponse(
            code: 501,
            httpMessage: "Not Implemented",
            message: "streaming chat is not yet supported on non-local tiers; rerun with stream:false or against `.local`",
            type: "stream_not_supported_yet",
            errorCode: "stream_not_supported_yet"
        )
        let fields = OpenAIAuditChain.AuditFields(
            ts: now,
            keyLabel: keyLabel,
            surface: "chat",
            modelLogged: routing.modelLogged,
            presetUsed: routing.presetUsed.rawValue,
            resolvedTier: routing.resolvedTier.rawValue,
            promptTokenCount: promptTokens,
            completionTokenCount: 0,
            status: "stream_not_supported_yet"
        )
        let bodies = OpenAIAuditChain.AuditBodies(
            requestBody: OpenAIChatHandler.requestSummary(request),
            responseBody: "[stream_not_supported_yet]"
        )
        return Outcome(
            httpStatus: 501,
            data: data,
            auditFields: fields,
            auditBodies: bodies
        )
    }

    // MARK: - V.13b-sse-b — streaming dispatch (Child B)

    /// V.13b-sse-b — outcome of a streaming dispatch through the Claude arm.
    /// The caller (ServeCommand streamHandler closure) wires `plan` into the
    /// listener's SSE drive, and wires `auditFieldsBuilder` into Plan.onFinish
    /// to record EXACTLY ONE audit row per streamed request — surface =
    /// `.chatStream`, httpStatus = 200, status = the FinishStatus `auditStatus`
    /// (V.13b-sse-d: `ok` / `client_cancel` / `upstream_error:<code>`).
    ///
    /// Shape choice (Karpathy r10): we expose the `auditFieldsBuilder` on the
    /// outcome rather than baking it into the Plan's existing `onFinish` so
    /// the caller controls the SINGLE audit-row site (same shape as the
    /// non-streaming `Outcome`, where `auditFields` is a public field).
    /// `Plan.onFinish` is set to a NO-OP here; ServeCommand wraps it.
    public struct StreamingOutcome: Sendable {
        public let plan: OpenAIChatStream.Plan
        public let auditFieldsBuilder: @Sendable (OpenAIChatStream.FinishStatus) -> OpenAIAuditChain.AuditFields
        public let auditBodiesBuilder: @Sendable () -> OpenAIAuditChain.AuditBodies

        public init(
            plan: OpenAIChatStream.Plan,
            auditFieldsBuilder: @escaping @Sendable (OpenAIChatStream.FinishStatus) -> OpenAIAuditChain.AuditFields,
            auditBodiesBuilder: @escaping @Sendable () -> OpenAIAuditChain.AuditBodies
        ) {
            self.plan = plan
            self.auditFieldsBuilder = auditFieldsBuilder
            self.auditBodiesBuilder = auditBodiesBuilder
        }
    }

    /// Sendable box for the terminal usage observed during a streamed
    /// response. `realPromptTokens` is captured at `.messageStart`;
    /// `realCompletionTokens` + `stopReason` are captured at `.messageDelta`.
    /// The `auditFieldsBuilder` closes over this box; readers race with the
    /// producer body but the writes are monotonic (one assignment per
    /// quantity) and the lock keeps reads consistent.
    private final class UsageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _promptTokens: Int?
        private var _completionTokens: Int?
        private var _stopReason: String?
        private var _accumulated = ""
        func setPrompt(_ v: Int?) { lock.lock(); _promptTokens = v; lock.unlock() }
        func setCompletion(_ v: Int?) { lock.lock(); _completionTokens = v; lock.unlock() }
        func setStopReason(_ v: String?) { lock.lock(); _stopReason = v; lock.unlock() }
        func appendText(_ s: String) { lock.lock(); _accumulated += s; lock.unlock() }
        var promptTokens: Int? { lock.lock(); defer { lock.unlock() }; return _promptTokens }
        var completionTokens: Int? { lock.lock(); defer { lock.unlock() }; return _completionTokens }
        var stopReason: String? { lock.lock(); defer { lock.unlock() }; return _stopReason }
        var accumulated: String { lock.lock(); defer { lock.unlock() }; return _accumulated }
    }

    /// V.13b-sse-b — translator: build a `StreamingOutcome` whose Plan opens
    /// `engine.chatStream(...)` lazily inside its `streamingEvents` producer
    /// body and translates each `AnthropicStreamEvent` into a pre-encoded
    /// `OpenAIChatStream.Chunk` data event (text-only this child; Child C
    /// wires tool_use).
    ///
    /// PURE-SYNC at construction (Karpathy P1) — runs on the listener
    /// queue. The upstream OPEN happens INSIDE the AsyncThrowingStream
    /// producer closure, which is invoked later on `ServeBridge.executor`.
    ///
    /// Frame mapping (text-only):
    ///   - `.messageStart(_, inputTokens)`: emit chunk with `delta:{role:"assistant"}`,
    ///     `finish_reason: null`. CAPTURE inputTokens.
    ///   - `.contentBlockStart(.text)` / `.contentBlockStop`: NO-OP at wire level.
    ///   - `.contentBlockDelta(_, .textDelta(text))`: emit chunk with
    ///     `delta:{content: text}`, `finish_reason: null`. ACCUMULATE text
    ///     for audit-row body capture.
    ///   - `.contentBlockStart(.toolUse(...))` / `.contentBlockDelta(.inputJsonDelta(...))`:
    ///     IGNORED (Child C will wire).
    ///   - `.messageDelta(stopReason, outputTokens)`: CAPTURE outputTokens +
    ///     stopReason. No wire emission.
    ///   - `.messageStop`: emit terminal chunk with `delta:{}` + mapped
    ///     `finish_reason` (`end_turn`/`stop_sequence` → "stop",
    ///     `max_tokens` → "length", default → "stop").
    ///   - `.error(type)`: THROW from producer body (propagates as a
    ///     clientCancel terminator via OpenAIChatStream.driveStreaming).
    ///
    /// `usage` is NOT emitted on the wire (Lauret P1 — envelope parity).
    public static func streamingPlan(
        engine: ClaudeAPIChatEngine,
        request: ChatCompletionRequest,
        routing: OpenAIChatHandler.Routing,
        keyLabel: String?,
        now: Date,
        id: String
    ) -> StreamingOutcome {
        // Capture immutable request metadata for audit-row builder. The
        // heuristic prompt-token count is computed up front and serves as
        // the fallback for the realPromptTokens-nil case.
        let promptText = request.messages.map(\.content).joined(separator: "\n")
        let heuristicPrompt = OpenAIChatHandler.estimateTokens(promptText)
        let createdEpoch = Int(now.timeIntervalSince1970)
        let usage = UsageBox()
        let model = routing.actualModel
        let messages = request.messages
        let tools = request.tools ?? []
        let requestSummary = OpenAIChatHandler.requestSummary(request)

        // Producer closure — invoked once per `OpenAIChatStream.run`.
        let producer: @Sendable () -> AsyncThrowingStream<Data, Error> = {
            AsyncThrowingStream<Data, Error> { continuation in
                let task = Task {
                    // V.13b-sse-c — per-block tool-use args accumulator.
                    // Local to the producer's Task scope (not UsageBox)
                    // because the args buffer is ONLY consulted by the
                    // defensive-concatenation validator at .messageDelta
                    // time and the messageStart input-token capture in
                    // UsageBox — never read from outside this Task body.
                    // Holding it on the stack avoids a needless lock and
                    // keeps the UsageBox surface focused on values the
                    // auditFieldsBuilder closure reads from outside.
                    var toolUseArgsByIndex: [Int: String] = [:]
                    do {
                        // Lazy open: this is where `engine.chatStream(...)`
                        // is invoked, on the producer Task (which the
                        // listener hosts on ServeBridge.executor on
                        // macOS-15+).
                        let upstream = engine.chatStream(
                            model: model, messages: messages, tools: tools
                        )
                        for try await event in upstream {
                            if Task.isCancelled { break }
                            switch event {
                            case .messageStart(_, let inputTokens):
                                usage.setPrompt(inputTokens)
                                let chunk = OpenAIChatStream.Chunk(
                                    id: id, created: createdEpoch, model: model,
                                    choices: [.init(
                                        index: 0,
                                        delta: .init(role: "assistant"),
                                        finishReason: nil
                                    )]
                                )
                                continuation.yield(
                                    OpenAIChatStream.sseEvent(OpenAIChatStream.encodeChunk(chunk))
                                )

                            case .contentBlockStart(let index, let block):
                                // Text block: NO-OP wire. tool_use: emit
                                // a HEADER fragment carrying Anthropic's
                                // id VERBATIM (Lauret P0 — tool_call id
                                // stability mirrors the non-stream
                                // round-trip in ClaudeAPIChatEngine.chat).
                                switch block {
                                case .text:
                                    continue
                                case .toolUse(let toolUseID, let name):
                                    toolUseArgsByIndex[index] = ""
                                    let chunk = OpenAIChatStream.Chunk(
                                        id: id, created: createdEpoch, model: model,
                                        choices: [.init(
                                            index: 0,
                                            delta: .init(toolCalls: [
                                                .init(
                                                    index: index,
                                                    id: toolUseID,
                                                    type: "function",
                                                    function: .init(name: name, arguments: "")
                                                )
                                            ]),
                                            finishReason: nil
                                        )]
                                    )
                                    continuation.yield(
                                        OpenAIChatStream.sseEvent(OpenAIChatStream.encodeChunk(chunk))
                                    )
                                }

                            case .contentBlockDelta(let index, let delta):
                                switch delta {
                                case .textDelta(let text):
                                    // Lauret sse-B re-audit P3 FOLD: skip empty
                                    // text_delta to mirror the local-MLX peer
                                    // (Sources/Core/OpenAIEndpoint/StreamingChat
                                    // Engine renderStreamingEvents guards
                                    // `guard !delta.content.isEmpty`). Anthropic
                                    // does not emit empty text_deltas in
                                    // practice, but cross-engine wire-shape
                                    // consistency is a Lauret invariant — OpenAI
                                    // clients shouldn't see empty content
                                    // chunks from one engine and not the other.
                                    guard !text.isEmpty else { continue }
                                    usage.appendText(text)
                                    let chunk = OpenAIChatStream.Chunk(
                                        id: id, created: createdEpoch, model: model,
                                        choices: [.init(
                                            index: 0,
                                            delta: .init(content: text),
                                            finishReason: nil
                                        )]
                                    )
                                    continuation.yield(
                                        OpenAIChatStream.sseEvent(OpenAIChatStream.encodeChunk(chunk))
                                    )
                                case .inputJsonDelta(let partial):
                                    // V.13b-sse-c — tool-use input fragments.
                                    // Accumulate per-block for the defensive
                                    // concatenation validation at messageDelta
                                    // time, and emit a CONTINUATION fragment
                                    // carrying ONLY `arguments` (sparse-encoded
                                    // via ToolCallFragment + FunctionFragment
                                    // encodeIfPresent — no id, no type, no
                                    // function.name).
                                    toolUseArgsByIndex[index, default: ""] += partial
                                    let chunk = OpenAIChatStream.Chunk(
                                        id: id, created: createdEpoch, model: model,
                                        choices: [.init(
                                            index: 0,
                                            delta: .init(toolCalls: [
                                                .init(
                                                    index: index,
                                                    function: .init(arguments: partial)
                                                )
                                            ]),
                                            finishReason: nil
                                        )]
                                    )
                                    continuation.yield(
                                        OpenAIChatStream.sseEvent(OpenAIChatStream.encodeChunk(chunk))
                                    )
                                }

                            case .contentBlockStop:
                                // Text block boundary: NO-OP wire.
                                // Tool_use block boundary: NO-OP wire (the
                                // terminal finish_reason chunk handles
                                // stream end). The args buffer remains
                                // intact for messageDelta validation.
                                continue

                            case .messageDelta(let stopReason, let outputTokens):
                                usage.setCompletion(outputTokens)
                                usage.setStopReason(stopReason)
                                // V.13b-sse-c — Schneier P1 defensive
                                // concatenation validation. If the upstream
                                // terminates with stop_reason="tool_use",
                                // each accumulated args buffer MUST parse as
                                // valid JSON; otherwise THROW a typed
                                // upstream error. The wire-level rendering
                                // of this throw is Child D's scope; here we
                                // surface the throw so the producer body's
                                // catch propagates it to the drive loop.
                                if stopReason == "tool_use" {
                                    // Lauret sse-C re-audit P3 FIX-NOW: a
                                    // stop_reason of "tool_use" with NO
                                    // tool_use blocks buffered is an upstream
                                    // protocol violation — the wire would
                                    // emit `finish_reason: "tool_calls"` with
                                    // no tool_calls header/continuation
                                    // anywhere, which is malformed OpenAI SSE.
                                    // Surface as a typed upstream error
                                    // (Child D renders the wire envelope).
                                    if toolUseArgsByIndex.isEmpty {
                                        throw ClaudeAPIChatEngineError.upstreamError(
                                            status: 502,
                                            type: "upstream_protocol_violation"
                                        )
                                    }
                                    // Lauret sse-C re-audit P3 FIX-NOW: use
                                    // `.allowFragments` so a legal-JSON
                                    // primitive (string/number/bool/null) at
                                    // the top level — unusual but RFC-valid
                                    // — doesn't trigger a false-positive
                                    // tool_arguments_malformed. Anthropic's
                                    // documented schema is `type: object` but
                                    // the validator stays aligned with raw
                                    // JSON. Deterministic iteration via
                                    // sorted keys so future error payloads
                                    // can surface the offending index.
                                    for index in toolUseArgsByIndex.keys.sorted() {
                                        let args = toolUseArgsByIndex[index] ?? ""
                                        let bytes = Data(args.utf8)
                                        if (try? JSONSerialization.jsonObject(
                                            with: bytes,
                                            options: [.allowFragments]
                                        )) == nil {
                                            throw ClaudeAPIChatEngineError.upstreamError(
                                                status: 502,
                                                type: "tool_arguments_malformed"
                                            )
                                        }
                                    }
                                }

                            case .messageStop:
                                let finishReason = mapStopReason(usage.stopReason)
                                let chunk = OpenAIChatStream.Chunk(
                                    id: id, created: createdEpoch, model: model,
                                    choices: [.init(
                                        index: 0,
                                        delta: .init(),
                                        finishReason: finishReason
                                    )]
                                )
                                continuation.yield(
                                    OpenAIChatStream.sseEvent(OpenAIChatStream.encodeChunk(chunk))
                                )

                            case .error(let type):
                                // Propagate as a producer throw — collapses
                                // to clientCancel at the drive layer.
                                //
                                // Lauret sse-B re-audit P3 boundary note:
                                // Child D wires the real upstream-error → OpenAI
                                // error-envelope translation + distinct audit
                                // status. For Child B today, an `.error` event
                                // arriving BEFORE `.messageStart` collapses to
                                // clientCancel with httpStatus=200 even when no
                                // prior chunk was emitted (OpenAI clients see an
                                // SSE stream that opens then dies silently). This
                                // is the documented Karpathy r10 P1 carve.
                                throw ClaudeAPIChatEngineError.upstreamError(
                                    status: 502, type: type
                                )
                            }
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        // V.13b-sse-d — extractor maps a producer-thrown error to the
        // short upstream code carried on the wire + audit row. Used by
        // OpenAIChatStream.driveStreaming to surface `.upstreamError(code:)`
        // instead of collapsing to `.clientCancel`.
        let extractor: @Sendable (Error) -> String? = { error in
            if let typed = error as? ClaudeAPIChatEngineError,
               case .upstreamError(_, let type) = typed {
                return type ?? "unknown"
            }
            return nil
        }
        let plan = OpenAIChatStream.Plan(
            head: OpenAIChatStream.head(),
            streamingEvents: producer,
            done: OpenAIChatStream.doneSentinel(),
            onFinish: { _ in
                // No-op: the caller (ServeCommand) wraps this Plan's
                // onFinish to call OpenAIServedRequestSink.record(...) via
                // the auditFieldsBuilder. This factory's caller wires the
                // SINGLE audit-row site — we just supply the builder.
            },
            errorTypeExtractor: extractor,
            errorTerminatorBuilder: ClaudeAPIServeDispatch.streamErrorLine(code:)
        )

        let auditFieldsBuilder: @Sendable (OpenAIChatStream.FinishStatus) -> OpenAIAuditChain.AuditFields = { status in
            let realPrompt = usage.promptTokens
            let realCompletion = usage.completionTokens
            let promptTokenCount = realPrompt ?? heuristicPrompt
            let completionTokenCount = realCompletion ?? OpenAIChatHandler.estimateTokens(usage.accumulated)
            return OpenAIAuditChain.AuditFields(
                ts: now,
                keyLabel: keyLabel,
                surface: "chat",
                modelLogged: routing.modelLogged,
                presetUsed: routing.presetUsed.rawValue,
                resolvedTier: routing.resolvedTier.rawValue,
                promptTokenCount: promptTokenCount,
                completionTokenCount: completionTokenCount,
                status: status.auditStatus
            )
        }

        let auditBodiesBuilder: @Sendable () -> OpenAIAuditChain.AuditBodies = {
            OpenAIAuditChain.AuditBodies(
                requestBody: requestSummary,
                responseBody: usage.accumulated
            )
        }

        return StreamingOutcome(
            plan: plan,
            auditFieldsBuilder: auditFieldsBuilder,
            auditBodiesBuilder: auditBodiesBuilder
        )
    }

    /// Map Anthropic `stop_reason` to OpenAI `finish_reason` for the
    /// terminal chunk. V.13b-sse-c wires the tool_use → tool_calls
    /// mapping so the translator's terminal chunk carries
    /// `finish_reason: "tool_calls"` when Anthropic ended on a tool_use
    /// block. Unknown / nil → "stop".
    static func mapStopReason(_ stopReason: String?) -> String {
        switch stopReason {
        case "end_turn", "stop_sequence", "stop", nil: return "stop"
        case "max_tokens": return "length"
        case "tool_use": return "tool_calls"
        default: return "stop"
        }
    }

    /// V.13b-4c — `backend_not_configured` rendering when no anthropic
    /// key was loaded at serve start (zero labels in the vault). The 503
    /// preserves today's stub text verbatim so existing operator tooling
    /// stays compatible.
    public static func backendNotConfiguredOutcome(
        request: ChatCompletionRequest,
        routing: OpenAIChatHandler.Routing,
        keyLabel: String?,
        now: Date
    ) -> Outcome {
        let promptText = request.messages.map(\.content).joined(separator: "\n")
        let promptTokens = OpenAIChatHandler.estimateTokens(promptText)
        let data = OpenAIChatServeBridge.backendNotConfiguredResponse(tier: routing.resolvedTier)
            ?? OpenAIChatHandler.errorResponse(
                code: 503, httpMessage: "Service Unavailable",
                message: "backend not configured", type: "backend_not_configured",
                errorCode: "backend_not_configured"
            )
        let fields = OpenAIAuditChain.AuditFields(
            ts: now,
            keyLabel: keyLabel,
            surface: "chat",
            modelLogged: routing.modelLogged,
            presetUsed: routing.presetUsed.rawValue,
            resolvedTier: routing.resolvedTier.rawValue,
            promptTokenCount: promptTokens,
            completionTokenCount: 0,
            status: "backend_not_configured"
        )
        let bodies = OpenAIAuditChain.AuditBodies(
            requestBody: OpenAIChatHandler.requestSummary(request),
            responseBody: "[backend_not_configured]"
        )
        return Outcome(
            httpStatus: 503,
            data: data,
            auditFields: fields,
            auditBodies: bodies
        )
    }

    // MARK: - V.13b-sse-d — wire-level error terminator (Child D)

    /// V.13b-sse-d — wire-level error terminator. ONE OpenAI SSE error
    /// line then close — NO `[DONE]` after (Schneier r10 P0 — OpenAI's
    /// real behavior; the error line is terminal). The body carries
    /// ONLY the short Anthropic `error.type` identifier (e.g.
    /// `overloaded_error`), NEVER `error.message` (info-leak guard).
    ///
    /// The `code` parameter is STRICTLY sanitized to `[A-Za-z0-9_]` —
    /// even if a future upstream parsing path returns a string with
    /// JSON-injection characters (quotes, braces, newlines), the
    /// sanitizer drops every byte that isn't an identifier character so
    /// the emitted SSE wire bytes cannot be smuggled into a fake event.
    public static func streamErrorLine(code: String) -> Data {
        // Schneier sse-D re-audit P3 FOLD: route through the single-source-
        // of-truth `FinishStatus.sanitizeCode` so the wire AND the audit-row
        // status are sanitized identically (whitelist + unknown fallback).
        let safe = OpenAIChatStream.FinishStatus.sanitizeCode(code)
        let envelope = #"{"error":{"type":"upstream_error","code":"\#(safe)"}}"#
        return Data("data: \(envelope)\n\n".utf8)
    }
}
