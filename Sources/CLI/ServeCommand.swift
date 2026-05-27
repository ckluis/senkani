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
        let authenticator = OpenAIListener.Authenticator { _, path, headers in
            OpenAIAuthGate.decide(
                authorizationHeader: headers["authorization"],
                requestedSurface: OpenAIAuthGate.surface(forPath: path),
                now: Date(),
                records: keys.current(),
                rateLimiter: rateLimiter
            )
        }

        // V.13a-3 — chat-completion surface. The per-request audit chain
        // and the placeholder completion engine live for the process
        // lifetime. The auth gate has already admitted the request before
        // the handler runs, so re-matching the key here only fetches the
        // record's preset + label for routing/telemetry.
        let auditChain = OpenAIAuditChain()
        let storeBodies = auditBodies
        // V.13e — persisted cross-process request log. The shared session DB
        // is the same handle the rest of senkani uses; the per-request write
        // is best-effort and microsecond-scale (queue.sync). Each served
        // request is recorded to BOTH the in-memory chain and this store via
        // `OpenAIServedRequestSink.record`, co-located at the prior
        // `auditChain.append` sites so the producer side is finally owned.
        let requestLogDB = SessionDatabase.shared
        let engine = Serve.placeholderChatEngine()
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
            let result = OpenAIChatHandler.handle(
                request: request,
                recordPreset: record?.preset ?? ModelPreset.auto.rawValue,
                keyLabel: record?.label,
                engine: engine,
                now: Date(),
                id: OpenAIChatHandler.generateID()
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
        // entry — no parallel stack); the placeholder engine returns a
        // deterministic, fixed-dimension vector so a client gets a valid
        // OpenAI `list` response while real on-device MiniLM inference lands
        // in the shared V.13 backend child. Each request lands exactly one
        // audit entry with `surface: "embeddings"`.
        let embeddingsEngine = Serve.placeholderEmbeddingsEngine()
        let embeddingsHandler = OpenAIListener.EmbeddingsHandler { _, _, headers, body in
            guard let request = OpenAIEmbeddingsHandler.decodeRequest(body) else {
                return OpenAIEmbeddingsHandler.errorResponse(
                    code: 400, httpMessage: "Bad Request",
                    message: "invalid embeddings request (expected JSON with a non-empty string or [string] `input`)",
                    type: "invalid_request_error", errorCode: "invalid_request"
                )
            }
            let token = OpenAIAuthGate.bearerToken(fromHeader: headers["authorization"])
            let record = token.flatMap { OpenAIAuthGate.matchRecord(presentedKey: $0, records: keys.current()) }
            let result = OpenAIEmbeddingsHandler.handle(
                request: request,
                keyLabel: record?.label,
                engine: embeddingsEngine,
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
            let result = OpenAIChatHandler.handle(
                request: request,
                recordPreset: record?.preset ?? ModelPreset.auto.rawValue,
                keyLabel: record?.label,
                engine: engine,
                now: Date(),
                id: OpenAIChatHandler.generateID()
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
            let telemetry = result.telemetry
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
                        status: status.rawValue
                    )
                    // The SSE response head was already sent with HTTP 200;
                    // `status` (ok/cancel) rides in `fields.status` for the
                    // in-memory chain, while the persisted row records the
                    // HTTP 200 that the client actually received.
                    OpenAIServedRequestSink.record(
                        chain: auditChain, fields: fields, bodies: bodies,
                        db: requestLogDB, surface: .chatStream, httpStatus: 200
                    )
                    print("openai-request surface=\(telemetry.surface) model_logged=\(telemetry.modelLogged) preset=\(telemetry.presetUsed) resolved_tier=\(telemetry.resolvedTier) stream=true status=\(status.rawValue)")
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
