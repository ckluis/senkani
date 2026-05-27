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

        // V.13a-2 — load the provisioned key snapshot from the on-disk
        // OpenAI-endpoint vault. The snapshot is read once at start; a key
        // provisioned with `senkani vault add openai-key` while the server
        // is already running is picked up on the next start (live reload is
        // out of scope for v13a-2).
        let vault = OpenAIKeyProvisioner.vault()
        let records = (try? await OpenAIKeyProvisioner.loadAll(vault: vault)) ?? []
        let keyCount = records.count

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
        // across all connections; the record snapshot is captured by value.
        let rateLimiter = OpenAIRateLimiter()
        let authenticator = OpenAIListener.Authenticator { _, path, headers in
            OpenAIAuthGate.decide(
                authorizationHeader: headers["authorization"],
                requestedSurface: OpenAIAuthGate.surface(forPath: path),
                now: Date(),
                records: records,
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
        let engine = Serve.placeholderChatEngine()
        let chatHandler = OpenAIListener.ChatHandler { _, _, headers, body in
            guard let request = OpenAIChatHandler.decodeRequest(body) else {
                return OpenAIChatHandler.errorResponse(
                    code: 400, httpMessage: "Bad Request",
                    message: "invalid chat completion request (expected JSON with string `content`)",
                    type: "invalid_request_error", errorCode: "invalid_request"
                )
            }
            if request.stream == true {
                return OpenAIChatHandler.errorResponse(
                    code: 400, httpMessage: "Bad Request",
                    message: "streaming is not supported on this endpoint yet (non-streaming only; SSE is V.13b)",
                    type: "invalid_request_error", errorCode: "streaming_unsupported"
                )
            }
            let token = OpenAIAuthGate.bearerToken(fromHeader: headers["authorization"])
            let record = token.flatMap { OpenAIAuthGate.matchRecord(presentedKey: $0, records: records) }
            let result = OpenAIChatHandler.handle(
                request: request,
                recordPreset: record?.preset ?? ModelPreset.auto.rawValue,
                keyLabel: record?.label,
                engine: engine,
                now: Date(),
                id: OpenAIChatHandler.generateID()
            )
            auditChain.append(result.auditFields, bodies: storeBodies ? result.auditBodies : nil)
            // Surface telemetry on the serve log — model_logged is the
            // client's ask, distinct from the resolved tier that ran.
            let t = result.telemetry
            print("openai-request surface=\(t.surface) model_logged=\(t.modelLogged) preset=\(t.presetUsed) resolved_tier=\(t.resolvedTier)")
            return OpenAIChatHandler.encodeResponse(result.response)
        }

        let listener = OpenAIListener(
            config: .init(bind: effective.bind, port: effective.port),
            authenticator: authenticator,
            chatHandler: chatHandler
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
        OpenAIChatHandler.Engine { model, messages in
            let prompt = messages.map(\.content).joined(separator: "\n")
            let content = "[senkani serve --openai] Routed to \(model). Live model inference is not yet wired in this build — V.13a-3 ships the OpenAI-compatible routing + audit surface; the real model backend lands in a later V.13 child."
            return OpenAIChatHandler.Completion(
                content: content,
                promptTokens: OpenAIChatHandler.estimateTokens(prompt),
                completionTokens: OpenAIChatHandler.estimateTokens(content)
            )
        }
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
