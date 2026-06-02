import ArgumentParser
import Foundation
import Core

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `senkani serve --openai [--bind <addr>] [--port <n>] [--accept-network-bind]`
///
/// V.13a-1 — OpenAI-compatible endpoint listener scaffold. Starts an
/// `NWListener`-backed HTTP listener (default `127.0.0.1:8470`), routes
/// every `/v1/*` path to `501 Not Implemented` (no surface wired yet),
/// logs the resolved bind + key-count, and runs until SIGINT/SIGTERM.
///
/// Security: a non-loopback `--bind` is default-deny — it requires
/// `--accept-network-bind` (or `accept_network_bind: true` in config)
/// AND at least one provisioned key. See `OpenAIListenerGuard`.
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run a local inference endpoint. Pass --openai for the OpenAI-compatible surface."
    )

    @Flag(name: .long, help: "Serve the OpenAI-compatible HTTP endpoint (/v1/*).")
    var openai = false

    @Option(name: .long, help: "Bind address. Default 127.0.0.1 (loopback). Non-loopback requires --accept-network-bind.")
    var bind: String?

    @Option(name: .long, help: "Bind port. Default 8470.")
    var port: Int?

    @Flag(name: .long, help: "Acknowledge a non-loopback bind. Required when --bind is not loopback.")
    var acceptNetworkBind = false

    @Flag(name: .long, help: "Store request/response bodies in the audit chain. Default off — only the request envelope + token counts are audited.")
    var auditBodies = false

    /// V.13b-4c — disambiguator for single-key-per-serve-process anthropic
    /// resolution. Required only when the vault has ≥2 anthropic-key labels
    /// (zero or one label resolve without a flag). Per-request key
    /// selection is deferred to the v13b-1 propagation child.
    @Option(name: .long, help: "Disambiguator when the vault has multiple anthropic-key labels (single-key-per-serve-process).")
    var anthropicKeyLabel: String?

    func run() async throws {
        guard openai else {
            print("use --openai (the only serve surface today)")
            return
        }

        // Loaded config is the persisted baseline; CLI flags override it
        // for this invocation only (no write-back).
        let loaded = OpenAIEndpointConfig.load()
        let effective = loaded.merging(
            bind: bind,
            port: port,
            acceptNetworkBind: acceptNetworkBind ? true : nil
        )

        // V.13a-2 hardening (process-gap-v13a-2-…-2026-05-27, Finding #1) —
        // a LIVE, mtime-gated snapshot of the on-disk OpenAI-endpoint key
        // set. The authenticator + handlers below call `keys.current()` per
        // request, so a key provisioned (or revoked) with
        // `senkani vault add/remove openai-key` while the server is already
        // running is picked up WITHOUT a restart — the file is re-read only
        // when its (mtime, size) advances. The start-time count feeds the
        // non-loopback-bind guard.
        let keys = OpenAIKeyRecordSnapshot()
        let keyCount = keys.current().count

        let outcome = OpenAIListenerGuard.evaluate(
            bind: effective.bind,
            port: effective.port,
            acceptNetworkBind: effective.acceptNetworkBind,
            keyCount: keyCount
        )
        if let warning = outcome.warning {
            FileHandle.standardError.write(Data((warning + "\n").utf8))
        }
        guard outcome.allowed else {
            let reason = outcome.abortReason ?? "refused to start"
            FileHandle.standardError.write(Data(("error: " + reason + "\n").utf8))
            throw ExitCode(2)
        }

        // Bearer-auth gate over the `/v1/*` prefix. One rate limiter shared
        // across all connections; the record set is read LIVE per request
        // via the mtime-gated snapshot so mid-serve provisioning/revocation
        // takes effect without a restart.
        let rateLimiter = OpenAIRateLimiter()
        // V.13e — persisted cross-process request log. Declared before the
        // authenticator so the gate-refusal recorder (below) can capture it.
        // The shared session DB is the same handle the rest of senkani uses;
        // each per-request write is best-effort and microsecond-scale
        // (queue.sync).
        let requestLogDB = SessionDatabase.shared
        let authenticator = OpenAIListener.Authenticator { _, path, headers in
            let snapshot = keys.current()
            let decision = OpenAIAuthGate.decide(
                authorizationHeader: headers["authorization"],
                requestedSurface: OpenAIAuthGate.surface(forPath: path),
                now: Date(),
                records: snapshot,
                rateLimiter: rateLimiter
            )
            // V.13e — a 401 / 403 / 429 is emitted here by the gate, BEFORE
            // any surface handler runs, so refused requests never reach the
            // success-path sink. Record them to the persisted request log
            // (metadata-only; the in-memory chain is deliberately untouched)
            // so doctor's trailing-24h 429-rate reflects real rejected
            // traffic. `decide` runs exactly once per `/v1/*` request ⇒ one
            // row per refusal, no double-count.
            OpenAIServedRequestSink.recordRefusal(
                decision: decision,
                path: path,
                authorizationHeader: headers["authorization"],
                records: snapshot,
                db: requestLogDB
            )
            return decision
        }

        // V.13a-3 — chat-completion surface. The per-request audit chain
        // and the placeholder completion engine live for the process
        // lifetime. The auth gate has already admitted the request before
        // the handler runs, so re-matching the key here only fetches the
        // record's preset + label for routing/telemetry.
        let auditChain = OpenAIAuditChain()
        let storeBodies = auditBodies

        // V.13b-4c — single-key-per-serve-process anthropic key resolution.
        // 0 labels in the vault: the today's 503 `backend_not_configured`
        // stub continues to fire for non-local tiers.
        // ≥1 label + present egress daemon: build the live engine via the
        // b-4a factory. The factory's `make` throws when the egress port
        // file is absent (a structural refusal — never a direct bypass).
        // The HARD enforcement gate from the b-4a re-audit: when the
        // operator has provisioned at least one anthropic key AND the
        // egress daemon's port file is absent at serve start, fail-fast
        // with stderr + ExitCode(2) (mirror lines 77-81). When no key is
        // provisioned, log a warning and keep today's 503 stub semantics.
        let anthropicVault = AnthropicKeyProvisioner.vault()
        let resolvedAnthropic: AnthropicKeyRecord?
        do {
            resolvedAnthropic = try await AnthropicKeyProvisioner.loadSingle(
                vault: anthropicVault, explicitLabel: anthropicKeyLabel
            )
        } catch let err as AnthropicKeyProvisioner.ProvisionError {
            FileHandle.standardError.write(Data(("error: anthropic-key resolution: \(err)\n").utf8))
            throw ExitCode(2)
        }

        let claudeEngine: ClaudeAPIChatEngine?
        let anthropicArmStatus: String
        if let record = resolvedAnthropic {
            do {
                // P2: 15s per-request deadline on the serve path (factory
                // default 30s is too high for the listener thread).
                claudeEngine = try ClaudeAPIServeEngineFactory.make(
                    apiKey: record.key,
                    requestTimeout: 15
                )
                // Log the label ONLY — never the raw key.
                anthropicArmStatus = "ready label=\(record.label)"
            } catch let err as ClaudeAPIServeEngineFactoryError {
                // Egress daemon absent AND at least one anthropic key
                // provisioned ⇒ structural refusal at startup (b-4a HARD
                // enforcement gate: no direct fallback to URLSession.shared).
                FileHandle.standardError.write(Data(("error: \(err)\n").utf8))
                throw ExitCode(2)
            }
        } else {
            claudeEngine = nil
            anthropicArmStatus = "unavailable reason=no_anthropic_key_in_vault"
        }
        print("openai-serve anthropic_arm=\(anthropicArmStatus)")

        // V.13b-4b — operator-actionable hint when api.anthropic.com lacks
        // an allow rule. NOTE: `serveEgressAllowHint(host:)` checks only
        // the host dimension; the live daemon gate uses `evaluate(request:)`
        // (host + method + scheme + body-class). A host-only allow that
        // silences this hint is also an allow on the live gate's host
        // dimension — directionally safe.
        let egressPolicyPath = NSHomeDirectory() + "/.senkani/egress-policy.json"
        let (egressPolicy, _) = EgressPolicy.load(from: egressPolicyPath)
        if let hint = egressPolicy.serveEgressAllowHint() {
            print("openai-serve egress-hint: \(hint)")
        }
        // V.13e — `requestLogDB` (declared above, alongside the authenticator)
        // is the persisted producer for SUCCESSFUL requests too: each surface
        // handler records to BOTH the in-memory chain and the persisted store
        // via `OpenAIServedRequestSink.record`, co-located at the prior
        // `auditChain.append` sites so the producer side is fully owned.
        //
        // V.13 real-chat (sub-item 1) — if the MCP target has registered a
        // real `ChatEngine` via `ModelManager.registerChatHandler`, the
        // registered handler produces real on-device Gemma 4 completions.
        // Otherwise we fall back to the v13a-3 placeholder. Non-streaming
        // surface only; SSE streaming continues to wrap whatever this
        // engine returns (proper token-by-token streaming lands in
        // sub-item 2). Readiness 503 + tokenizer-accurate usage land in
        // sub-item 3.
        let registeredChatHandler = ModelManager.shared.resolvedChatHandler()
        if registeredChatHandler == nil {
            print("openai-serve chat_backend=placeholder (no MCP-side ChatEngine registered; completions are v13a-3 placeholder text)")
        } else {
            print("openai-serve chat_backend=mcp_handler (Gemma 4 RAM-tier-resolved)")
        }
        let engine = registeredChatHandler
            .map(OpenAIChatServeBridge.syncEngine)
            ?? Serve.placeholderChatEngine()
        let chatHandler = OpenAIListener.ChatHandler { _, _, headers, body in
            guard let request = OpenAIChatHandler.decodeRequest(body) else {
                return OpenAIChatHandler.errorResponse(
                    code: 400, httpMessage: "Bad Request",
                    message: "invalid chat completion request (expected JSON with string `content`)",
                    type: "invalid_request_error", errorCode: "invalid_request"
                )
            }
            // V.13b — streaming requests are handled by `streamHandler`
            // ahead of this non-streaming surface; if one reaches here the
            // stream flag is absent or false (or a tool-use stream bailed
            // here for its precise error rendering).
            let token = OpenAIAuthGate.bearerToken(fromHeader: headers["authorization"])
            let record = token.flatMap { OpenAIAuthGate.matchRecord(presentedKey: $0, records: keys.current()) }
            // V.13d — tool-use pre-flight: malformed tools → 400, a key
            // without the `tools` scope → 403 (insufficient_scope). The
            // `tools` scope is body-derived, so it is enforced here rather
            // than in the path-only auth gate.
            if let preflight = OpenAIChatHandler.toolsPreflightError(request: request, scope: record?.scope ?? []) {
                return preflight
            }
            // V.13 real-chat (sub-item 3) — pre-dispatch tier gate. Routing
            // is pure / cheap; we run it here so the resolved tier drives
            // the dispatch decision BEFORE the (potentially expensive)
            // engine call. Non-local tiers route to the LIVE Claude arm
            // (b-4c) when configured, else to today's 503 stub.
            let preRouting = OpenAIChatHandler.route(
                request: request,
                recordPreset: record?.preset ?? ModelPreset.auto.rawValue
            )
            let now = Date()
            let chatId = OpenAIChatHandler.generateID()
            let anthropicKeyLabelForAudit = resolvedAnthropic?.label

            // V.13b-4c — non-local tiers route to the Claude arm.
            if preRouting.resolvedTier != .local {
                // stream:true non-local: complete framed 501 BEFORE any
                // SSE byte; the streamHandler returns nil for this case so
                // the listener never opens the stream. Single audit row.
                // Priority note (Karpathy re-audit FOLD): stream:true is
                // checked BEFORE the claudeEngine-nil guard, so an operator
                // with no anthropic key + stream:true on a non-local tier
                // gets 501 stream_not_supported_yet (more durable refusal —
                // streaming non-local will still be unsupported once a key
                // is provisioned) rather than 503 backend_not_configured.
                if request.stream == true {
                    let outcome = ClaudeAPIServeDispatch.streamNotSupportedOutcome(
                        request: request,
                        routing: preRouting,
                        keyLabel: anthropicKeyLabelForAudit,
                        now: now
                    )
                    OpenAIServedRequestSink.record(
                        chain: auditChain,
                        fields: outcome.auditFields,
                        bodies: storeBodies ? outcome.auditBodies : nil,
                        db: requestLogDB, surface: .chat, httpStatus: outcome.httpStatus
                    )
                    print("openai-request surface=chat model_logged=\(preRouting.modelLogged) preset=\(preRouting.presetUsed.rawValue) resolved_tier=\(preRouting.resolvedTier.rawValue) status=stream_not_supported_yet")
                    return outcome.data
                }
                guard let claudeEngine else {
                    // Zero anthropic keys in the vault ⇒ preserve today's
                    // 503 backend_not_configured stub semantics.
                    let outcome = ClaudeAPIServeDispatch.backendNotConfiguredOutcome(
                        request: request, routing: preRouting,
                        keyLabel: anthropicKeyLabelForAudit, now: now
                    )
                    OpenAIServedRequestSink.record(
                        chain: auditChain,
                        fields: outcome.auditFields,
                        bodies: storeBodies ? outcome.auditBodies : nil,
                        db: requestLogDB, surface: .chat, httpStatus: outcome.httpStatus
                    )
                    print("openai-request surface=chat model_logged=\(preRouting.modelLogged) preset=\(preRouting.presetUsed.rawValue) resolved_tier=\(preRouting.resolvedTier.rawValue) status=backend_not_configured")
                    return outcome.data
                }
                // Live dispatch through the Claude engine. The dispatch
                // helper runs chat() OFF the listener thread + catches the
                // typed `ClaudeAPIChatEngineError` so the wire shape + real
                // httpStatus land in EXACTLY ONE place (no `try?` swallow).
                let outcome = ClaudeAPIServeDispatch.dispatch(
                    engine: claudeEngine,
                    request: request,
                    routing: preRouting,
                    keyLabel: anthropicKeyLabelForAudit,
                    now: now,
                    id: chatId
                )
                OpenAIServedRequestSink.record(
                    chain: auditChain,
                    fields: outcome.auditFields,
                    bodies: storeBodies ? outcome.auditBodies : nil,
                    db: requestLogDB, surface: .chat, httpStatus: outcome.httpStatus
                )
                print("openai-request surface=chat model_logged=\(preRouting.modelLogged) preset=\(preRouting.presetUsed.rawValue) resolved_tier=\(preRouting.resolvedTier.rawValue) status=\(outcome.auditFields.status) http_status=\(outcome.httpStatus)")
                return outcome.data
            }

            // V.13 real-chat (sub-item 3) — readiness gate fires ONLY when
            // a real chat handler is registered AND the local Gemma 4
            // model isn't installed for this machine's RAM. The placeholder
            // path stays available without any model (matches v13c
            // embeddings semantics).
            if registeredChatHandler != nil {
                let ready = ModelManager.shared.anyGemma4Ready()
                if let readinessGate = OpenAIChatServeBridge.readinessResponse(
                    modelTier: preRouting.resolvedTier, isReady: ready
                ) {
                    print("openai-request surface=chat model_logged=\(preRouting.modelLogged) resolved_tier=\(preRouting.resolvedTier.rawValue) status=model_not_available")
                    return readinessGate
                }
            }
            let result = OpenAIChatHandler.handle(
                request: request,
                recordPreset: record?.preset ?? ModelPreset.auto.rawValue,
                keyLabel: record?.label,
                engine: engine,
                now: now,
                id: chatId
            )
            OpenAIServedRequestSink.record(
                chain: auditChain,
                fields: result.auditFields,
                bodies: storeBodies ? result.auditBodies : nil,
                db: requestLogDB, surface: .chat, httpStatus: 200
            )
            // Surface telemetry on the serve log — model_logged is the
            // client's ask, distinct from the resolved tier that ran.
            let t = result.telemetry
            print("openai-request surface=\(t.surface) model_logged=\(t.modelLogged) preset=\(t.presetUsed) resolved_tier=\(t.resolvedTier)")
            return OpenAIChatHandler.encodeResponse(result.response)
        }

        // V.13c — embeddings surface. The embedding model identity is
        // sourced from `ModelManager` (the single `minilm-l6` registry
        // entry — no parallel stack). V.13c-real-engine: if the MCP target
        // has registered a real `EmbeddingEngine` via
        // `ModelManager.registerEmbeddingHandler`, the registered handler
        // produces real on-device MiniLM vectors (+ real tokenizer count
        // for `usage.prompt_tokens`); otherwise we fall back to the v13c
        // placeholder and log the unregistered state once at startup. The
        // readiness gate fires ONLY when a real handler is registered AND
        // the model is not yet downloaded — the placeholder path stays
        // available without any model.
        let placeholderEmbeddingsEngine = Serve.placeholderEmbeddingsEngine()
        let registeredEmbeddingHandler = ModelManager.shared.resolvedEmbeddingHandler()
        if registeredEmbeddingHandler == nil {
            print("openai-serve embeddings_backend=placeholder (no MCP-side EmbeddingEngine registered; vectors are deterministic, not real MiniLM embeddings)")
        } else {
            print("openai-serve embeddings_backend=mcp_handler model_id=\(ModelManager.embeddingModelID)")
        }
        let embeddingsHandler = OpenAIListener.EmbeddingsHandler { _, _, headers, body in
            guard let request = OpenAIEmbeddingsHandler.decodeRequest(body) else {
                return OpenAIEmbeddingsHandler.errorResponse(
                    code: 400, httpMessage: "Bad Request",
                    message: "invalid embeddings request (expected JSON with a non-empty string or [string] `input`)",
                    type: "invalid_request_error", errorCode: "invalid_request"
                )
            }
            // Readiness gate fires only when a real handler is registered —
            // the placeholder path doesn't need the model and stays
            // available without it (Q1+Q2 scope decisions 2026-05-28).
            let engine: OpenAIEmbeddingsHandler.Engine
            if let registered = registeredEmbeddingHandler {
                let modelId = ModelManager.embeddingModelID
                let ready = ModelManager.shared.isReady(modelId)
                if let gate = OpenAIEmbeddingsServeBridge.readinessResponse(
                    modelId: modelId, isReady: ready
                ) {
                    print("openai-request surface=embeddings model_logged=\(request.model) resolved_model=\(modelId) status=model_not_available")
                    return gate
                }
                engine = OpenAIEmbeddingsServeBridge.syncEngine(for: registered)
            } else {
                engine = placeholderEmbeddingsEngine
            }
            let token = OpenAIAuthGate.bearerToken(fromHeader: headers["authorization"])
            let record = token.flatMap { OpenAIAuthGate.matchRecord(presentedKey: $0, records: keys.current()) }
            let result = OpenAIEmbeddingsHandler.handle(
                request: request,
                keyLabel: record?.label,
                engine: engine,
                now: Date()
            )
            OpenAIServedRequestSink.record(
                chain: auditChain,
                fields: result.auditFields,
                bodies: storeBodies ? result.auditBodies : nil,
                db: requestLogDB, surface: .embeddings, httpStatus: 200
            )
            let t = result.telemetry
            print("openai-request surface=\(t.surface) model_logged=\(t.modelLogged) resolved_model=\(t.resolvedModel) inputs=\(t.inputCount)")
            return OpenAIEmbeddingsHandler.encodeResponse(result.response)
        }

        // V.13 real-chat sub-item 2 — registered streaming handler. When
        // present (MCP target started), a content stream's SSE deltas come
        // from MLX's `container.generate` `AsyncStream<Generation>` as they
        // arrive, NOT v13b's post-hoc content chunking. Tool-call streams
        // continue to ride the v13b collected-then-chunk path so v13d-1's
        // tool-call contract is preserved.
        let registeredStreamingChatHandler = ModelManager.shared.resolvedStreamingChatHandler()
        if registeredStreamingChatHandler == nil {
            print("openai-serve chat_streaming_backend=collected_then_chunk (no MCP-side StreamingChatEngine registered; SSE content deltas use the v13b post-hoc chunking path)")
        } else {
            print("openai-serve chat_streaming_backend=mcp_streaming_handler (real token-by-token Gemma 4 deltas)")
        }

        // V.13b — SSE streaming surface. Returns a plan only when the
        // client asked to stream (`stream: true`); otherwise nil → the
        // non-streaming `chatHandler` above serves the request. Auth + rate
        // limiting are enforced by the gate BEFORE this runs, so a streamed
        // request that opens here has already cleared the rate window — a
        // 429 is a complete framed response emitted ahead of any SSE byte.
        let streamHandler = OpenAIListener.StreamHandler { _, _, headers, body in
            guard let request = OpenAIChatHandler.decodeRequest(body), request.stream == true else {
                return nil
            }
            let token = OpenAIAuthGate.bearerToken(fromHeader: headers["authorization"])
            let record = token.flatMap { OpenAIAuthGate.matchRecord(presentedKey: $0, records: keys.current()) }
            // V.13d — a malformed or out-of-scope tool-use stream falls
            // through to the non-streaming handler, which renders the exact
            // 400/403 as a complete framed response BEFORE any SSE byte (the
            // listener never opens the stream for a nil plan). V.13d-1 makes
            // a VALID, in-scope tool-use stream emit `tool_calls` deltas
            // (below) rather than dropping the call into empty content.
            if OpenAIChatHandler.toolsPreflightError(request: request, scope: record?.scope ?? []) != nil {
                return nil
            }

            let routing = OpenAIChatHandler.route(
                request: request,
                recordPreset: record?.preset ?? ModelPreset.auto.rawValue
            )
            // V.13b-sse-b — streaming requests on non-local tiers route to
            // the LIVE Anthropic SSE arm when an anthropic key is configured.
            // The `claudeEngine == nil` case STAYS as nil here, so the
            // chatHandler still renders today's 501 `stream_not_supported_yet`
            // BEFORE any SSE byte (preserves the operator-actionable hint for
            // unconfigured systems). The configured-engine case is handled
            // below via `ClaudeAPIServeDispatch.streamingPlan(...)`.
            if routing.resolvedTier != .local {
                guard let claudeEngine else { return nil }
                let now = Date()
                let chatId = OpenAIChatHandler.generateID()
                let keyLabel = record?.label
                let outcome = ClaudeAPIServeDispatch.streamingPlan(
                    engine: claudeEngine,
                    request: request,
                    routing: routing,
                    keyLabel: keyLabel,
                    now: now,
                    id: chatId
                )
                // Wrap the Plan's onFinish so the SINGLE audit-row site is
                // owned here (mirror of the non-streaming chatHandler's
                // OpenAIServedRequestSink.record(...) call).
                let resolvedTierStr = routing.resolvedTier.rawValue
                let presetUsedStr = routing.presetUsed.rawValue
                let modelLoggedStr = routing.modelLogged
                let basePlan = outcome.plan
                let auditFieldsBuilder = outcome.auditFieldsBuilder
                let auditBodiesBuilder = outcome.auditBodiesBuilder
                let storeBodiesLocal = storeBodies
                // Lauret sse-B re-audit P3 defensive guard: streamingPlan()
                // currently always constructs via the streaming Plan init, so
                // `streamingEvents` is never nil — but a future StreamingOutcome
                // variant (e.g. error-early-render in Child D) could surface a
                // non-streaming Plan. Guard against that future-developer
                // footgun by falling through to the chatHandler-rendered 501
                // path rather than crashing the listener on a force-unwrap.
                guard let events = basePlan.streamingEvents else { return nil }
                return OpenAIChatStream.Plan(
                    head: basePlan.head,
                    streamingEvents: events,
                    done: basePlan.done,
                    onFinish: { status in
                        let fields = auditFieldsBuilder(status)
                        let bodies = storeBodiesLocal ? auditBodiesBuilder() : nil
                        OpenAIServedRequestSink.record(
                            chain: auditChain, fields: fields, bodies: bodies,
                            db: requestLogDB, surface: .chatStream, httpStatus: 200
                        )
                        print("openai-request surface=chat model_logged=\(modelLoggedStr) preset=\(presetUsedStr) resolved_tier=\(resolvedTierStr) stream=true backend=claude_api status=\(status.auditStatus)")
                    }
                )
            }
            if registeredChatHandler != nil {
                let ready = ModelManager.shared.anyGemma4Ready()
                if OpenAIChatServeBridge.readinessResponse(
                    modelTier: routing.resolvedTier, isReady: ready
                ) != nil {
                    return nil
                }
            }
            let now = Date()
            let createdEpoch = Int(now.timeIntervalSince1970)
            let id = OpenAIChatHandler.generateID()
            let promptText = request.messages.map(\.content).joined(separator: "\n")
            let promptTokens = OpenAIChatHandler.estimateTokens(promptText)
            let modelLogged = routing.modelLogged
            let resolvedTier = routing.resolvedTier.rawValue
            let presetUsed = routing.presetUsed.rawValue
            let requestSummary = OpenAIChatHandler.requestSummary(request)

            // V.13 real-chat sub-item 2 — content-stream path through the
            // registered streaming handler, ONLY for non-tool-use requests
            // and when an `MLXStreamingChatEngineAdapter` is registered.
            // Tool-use requests + unregistered handler fall through to the
            // v13b collected-then-chunk path below.
            let usesTools = OpenAIChatHandler.requestUsesTools(request)
            if !usesTools, let streamingHandler = registeredStreamingChatHandler {
                // Accumulator captures content as it streams so the audit
                // entry's `completion_token_count` reflects what was
                // actually sent. Lock-protected because the producer Task
                // and the listener's onFinish run on different queues.
                final class Accumulator: @unchecked Sendable {
                    private let lock = NSLock()
                    private var buffer = ""
                    func append(_ s: String) { lock.lock(); buffer += s; lock.unlock() }
                    func snapshot() -> String { lock.lock(); defer { lock.unlock() }; return buffer }
                }
                let accumulator = Accumulator()

                let messages = request.messages
                let tools = request.tools ?? []
                let model = routing.actualModel
                let sourceProvider: @Sendable () -> AsyncThrowingStream<Data, Error> = {
                    let upstream = streamingHandler.stream(
                        model: model, messages: messages, tools: tools
                    )
                    // Tee deltas into the accumulator so the audit token
                    // count reflects what actually streamed.
                    let teed = AsyncThrowingStream<OpenAIChatHandler.TokenDelta, Error> { continuation in
                        let task = Task {
                            do {
                                for try await delta in upstream {
                                    if Task.isCancelled { break }
                                    accumulator.append(delta.content)
                                    continuation.yield(delta)
                                }
                                continuation.finish()
                            } catch {
                                continuation.finish(throwing: error)
                            }
                        }
                        continuation.onTermination = { _ in task.cancel() }
                    }
                    return OpenAIChatHandler.renderStreamingEvents(
                        id: id, created: createdEpoch, model: model, source: teed
                    )
                }

                let keyLabel = record?.label
                return OpenAIChatStream.Plan(
                    head: OpenAIChatStream.head(),
                    streamingEvents: sourceProvider,
                    done: OpenAIChatStream.doneSentinel(),
                    onFinish: { status in
                        let completion = accumulator.snapshot()
                        let completionTokens = OpenAIChatHandler.estimateTokens(completion)
                        let fields = OpenAIAuditChain.AuditFields(
                            ts: now, keyLabel: keyLabel, surface: "chat",
                            modelLogged: routing.modelLogged,
                            presetUsed: routing.presetUsed.rawValue,
                            resolvedTier: routing.resolvedTier.rawValue,
                            promptTokenCount: promptTokens,
                            completionTokenCount: completionTokens,
                            status: status.auditStatus
                        )
                        let bodies = storeBodies
                            ? OpenAIAuditChain.AuditBodies(
                                requestBody: requestSummary,
                                responseBody: completion
                              )
                            : nil
                        OpenAIServedRequestSink.record(
                            chain: auditChain, fields: fields, bodies: bodies,
                            db: requestLogDB, surface: .chatStream, httpStatus: 200
                        )
                        print("openai-request surface=chat model_logged=\(modelLogged) preset=\(presetUsed) resolved_tier=\(resolvedTier) stream=true backend=mcp_streaming status=\(status.auditStatus)")
                    }
                )
            }

            // V.13b fallback path: collected-then-chunk. Used for tool-use
            // streams (v13d-1 contract) and whenever no streaming handler is
            // registered (e.g. `senkani serve` started without the MCP hook,
            // unit-test runs).
            let result = OpenAIChatHandler.handle(
                request: request,
                recordPreset: record?.preset ?? ModelPreset.auto.rawValue,
                keyLabel: record?.label,
                engine: engine,
                now: now,
                id: id
            )
            let response = result.response
            // V.13d-1 — a tool-call completion streams `tool_calls` deltas
            // (header fragment + arguments fragments + terminal
            // `finish_reason: "tool_calls"`); a normal completion streams
            // content chunks. Both ride the same `Chunk`/`run` machinery.
            let message = response.choices.first?.message
            let events: [Data]
            if let toolCalls = message?.toolCalls, !toolCalls.isEmpty {
                events = OpenAIChatStream.toolCallEvents(
                    id: response.id, created: response.created,
                    model: response.model, toolCalls: toolCalls
                )
            } else {
                let content = message?.content ?? ""
                events = OpenAIChatStream.events(
                    id: response.id, created: response.created,
                    model: response.model, content: content
                )
            }
            let base = result.auditFields
            let bodies = storeBodies ? result.auditBodies : nil
            let fallbackTelemetry = result.telemetry
            return OpenAIChatStream.Plan(
                head: OpenAIChatStream.head(),
                events: events,
                done: OpenAIChatStream.doneSentinel(),
                onFinish: { status in
                    // Exactly one audit entry per streamed request; `status`
                    // distinguishes completion (`ok`) from client-cancel.
                    let fields = OpenAIAuditChain.AuditFields(
                        ts: base.ts, keyLabel: base.keyLabel, surface: base.surface,
                        modelLogged: base.modelLogged, presetUsed: base.presetUsed,
                        resolvedTier: base.resolvedTier,
                        promptTokenCount: base.promptTokenCount,
                        completionTokenCount: base.completionTokenCount,
                        status: status.auditStatus
                    )
                    // The SSE response head was already sent with HTTP 200;
                    // `status` (ok/cancel) rides in `fields.status` for the
                    // in-memory chain, while the persisted row records the
                    // HTTP 200 that the client actually received.
                    OpenAIServedRequestSink.record(
                        chain: auditChain, fields: fields, bodies: bodies,
                        db: requestLogDB, surface: .chatStream, httpStatus: 200
                    )
                    print("openai-request surface=\(fallbackTelemetry.surface) model_logged=\(fallbackTelemetry.modelLogged) preset=\(fallbackTelemetry.presetUsed) resolved_tier=\(fallbackTelemetry.resolvedTier) stream=true status=\(status.auditStatus)")
                }
            )
        }

        let listener = OpenAIListener(
            config: .init(bind: effective.bind, port: effective.port),
            authenticator: authenticator,
            chatHandler: chatHandler,
            embeddingsHandler: embeddingsHandler,
            streamHandler: streamHandler
        )
        try listener.start()
        print(OpenAIListener.startupLog(bind: effective.bind, port: listener.port, keyCount: keyCount))

        // Park until SIGINT/SIGTERM, then stop the listener cleanly.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigQueue = DispatchQueue(label: "com.senkani.serve-signals")
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: sigQueue)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: sigQueue)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumer = ContinuationOnce(continuation)
            sigint.setEventHandler { resumer.resume() }
            sigterm.setEventHandler { resumer.resume() }
            sigint.resume()
            sigterm.resume()
        }
        _ = (sigint, sigterm)   // keep the sources alive until shutdown
        listener.stop()
    }

    /// V.13a-3 — placeholder completion engine. This child ships the
    /// routing + audit SURFACE; real in-process model inference is a later
    /// V.13 child. The placeholder returns a well-formed, honest
    /// completion that names the model the request routed to, so a client
    /// gets a valid `chat.completion` and an unambiguous signal that the
    /// model backend is not yet connected. Token counts are estimated from
    /// the real prompt + content.
    static func placeholderChatEngine() -> OpenAIChatHandler.Engine {
        OpenAIChatHandler.Engine { model, messages, tools in
            let prompt = messages.map(\.content).joined(separator: "\n")
            // V.13d — when the client declares tools AND the conversation
            // has not yet returned a tool result (no prior `role: "tool"`
            // message), the placeholder "calls" the first declared tool so
            // the round-trip is exercised. The called name bridges through
            // `MCPToolConfig` (OpenAIToolBridge) — no parallel registry. Once
            // a tool result is in context (multi-turn), it returns text.
            let hasToolResult = messages.contains { $0.role == "tool" }
            if let bridged = OpenAIToolBridge.bridge(tools).first, !hasToolResult {
                let args = "{}"
                let call = OpenAIToolCall(
                    id: "call_\(OpenAIChatHandler.generateID().dropFirst("chatcmpl-".count))",
                    function: .init(name: bridged.name, arguments: args)
                )
                return OpenAIChatHandler.Completion(
                    content: "",
                    toolCalls: [call],
                    promptTokens: OpenAIChatHandler.estimateTokens(prompt),
                    completionTokens: OpenAIChatHandler.estimateTokens(args)
                )
            }
            let content = "[senkani serve --openai] Routed to \(model). Live model inference is not yet wired in this build — V.13a-3 ships the OpenAI-compatible routing + audit surface; the real model backend lands in a later V.13 child."
            return OpenAIChatHandler.Completion(
                content: content,
                promptTokens: OpenAIChatHandler.estimateTokens(prompt),
                completionTokens: OpenAIChatHandler.estimateTokens(content)
            )
        }
    }

    /// V.13c — placeholder embeddings engine. The model IDENTITY is sourced
    /// from `ModelManager` by `OpenAIEmbeddingsHandler.handle` (no parallel
    /// stack); this engine produces the VECTORS. Real on-device MiniLM
    /// inference is the shared V.13 backend child — until it lands, the
    /// engine returns a deterministic, L2-normalized `dimension`-wide vector
    /// per input so a client gets a well-formed OpenAI `list` response. The
    /// vectors are a placeholder, NOT real embeddings; the serve log + audit
    /// chain record the request honestly.
    static func placeholderEmbeddingsEngine() -> OpenAIEmbeddingsHandler.Engine {
        // MiniLM-L6-v2 is 384-dimensional; match it so downstream clients see
        // the production dimension.
        let dimension = 384
        return OpenAIEmbeddingsHandler.Engine { _, inputs in
            let vectors: [[Float]] = inputs.map { text in
                Serve.deterministicVector(for: text, dimension: dimension)
            }
            return OpenAIEmbeddingsHandler.Embedding(
                vectors: vectors,
                promptTokens: OpenAIEmbeddingsHandler.estimateTokens(inputs)
            )
        }
    }

    /// Deterministic, L2-normalized pseudo-vector from a text seed. Stable
    /// for a given input so callers/tests get reproducible output; NOT a
    /// semantic embedding (the real MiniLM path is the deferred backend).
    static func deterministicVector(for text: String, dimension: Int) -> [Float] {
        // A tiny SplitMix64-style PRNG seeded by the FNV-1a hash of the text.
        var state: UInt64 = 1_469_598_103_934_665_603
        for byte in text.utf8 {
            state = (state ^ UInt64(byte)) &* 1_099_511_628_211
        }
        var raw = [Float](repeating: 0, count: dimension)
        for i in 0..<dimension {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z = z ^ (z >> 31)
            // Map to [-1, 1).
            raw[i] = Float(Double(z) / Double(UInt64.max)) * 2 - 1
        }
        let norm = sqrt(raw.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return raw }
        return raw.map { $0 / norm }
    }
}

/// Resumes a `CheckedContinuation` at most once, even if both signal
/// sources (or repeated signals) fire — a double-resume would crash.
private final class ContinuationOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}
