import Foundation

/// V.13a-1 — pre-flight admission guard for the OpenAI-compatible
/// endpoint. Pure, side-effect-free, and fully testable without binding
/// a socket: it decides whether a given (bind, accept-flag, key-count)
/// tuple may start, and produces the operator-facing warning string for
/// any non-loopback bind.
///
/// Security contract (Schneier P0, ships in v13a-1):
///   - A loopback bind (`127.0.0.1` / `::1` / `localhost`) is always
///     allowed and emits no warning — the trust boundary is the local
///     user.
///   - A non-loopback bind is DEFAULT-DENY. It requires BOTH an explicit
///     operator acknowledgement (`--accept-network-bind` or
///     `accept_network_bind: true`) AND at least one provisioned key in
///     the CredentialVault. Missing either → refuse to start (the caller
///     aborts non-zero). Either way, a non-loopback bind always prints a
///     warning naming the exposed surface.
public enum OpenAIListenerGuard {

    /// Result of evaluating a candidate bind.
    public struct Outcome: Sendable, Equatable {
        /// True if the listener may start.
        public let allowed: Bool
        /// Operator warning naming the exposed surface. Non-nil for every
        /// non-loopback bind (printed whether or not the bind is allowed);
        /// nil for loopback.
        public let warning: String?
        /// Human-readable refusal reason. Non-nil iff `allowed == false`.
        public let abortReason: String?

        public init(allowed: Bool, warning: String?, abortReason: String?) {
            self.allowed = allowed
            self.warning = warning
            self.abortReason = abortReason
        }
    }

    /// Loopback test. `0.0.0.0` (all interfaces) and `::` are explicitly
    /// NOT loopback — those are the most exposed binds.
    public static func isLoopback(_ bind: String) -> Bool {
        switch bind.lowercased() {
        case "127.0.0.1", "::1", "localhost", "0:0:0:0:0:0:0:1":
            return true
        default:
            // Any 127.0.0.0/8 address is loopback.
            return bind.hasPrefix("127.")
        }
    }

    public static func evaluate(
        bind: String,
        port: Int,
        acceptNetworkBind: Bool,
        keyCount: Int
    ) -> Outcome {
        if isLoopback(bind) {
            return Outcome(allowed: true, warning: nil, abortReason: nil)
        }
        let surface = "\(bind):\(port)"
        let warning = "⚠️  senkani serve --openai is binding NON-LOOPBACK at \(surface) — "
            + "this exposes an inference surface to the network."
        if !acceptNetworkBind {
            return Outcome(
                allowed: false,
                warning: warning,
                abortReason: "refusing to bind non-loopback \(surface) without "
                    + "--accept-network-bind (or accept_network_bind: true in config)."
            )
        }
        if keyCount <= 0 {
            return Outcome(
                allowed: false,
                warning: warning,
                abortReason: "refusing to bind non-loopback \(surface) with zero "
                    + "provisioned keys — provision a key (v13a-2) before exposing "
                    + "the endpoint to the network."
            )
        }
        return Outcome(allowed: true, warning: warning, abortReason: nil)
    }
}

#if canImport(Network)
import Network

/// V.13a-1 — `NWListener`-backed HTTP listener scaffold for the
/// OpenAI-compatible endpoint. Substrate decision (operator, 2026-05-27):
/// `Network.framework`, no new SwiftPM dependency. v13b layers SSE via
/// manual chunked writes on the accepted `NWConnection`; v13a-3 replaces
/// the 501 stub with a real `/v1/chat/completions` handler.
///
/// This child proves the listener lifecycle only — start, bind (loopback
/// by default via `requiredLocalEndpoint`), route every `/v1/*` path to
/// `501 Not Implemented`, log, and stop cleanly with no leaked port.
///
/// Lifecycle (mirrors `EgressListener`'s idempotency contract):
///   - `start()` binds + waits (bounded) for the listener to reach
///     `.ready`, then records the bound port. Idempotent — a second call
///     while running is a no-op.
///   - `stop()` cancels the listener and zeroes the bound port.
///     Idempotent.
///
/// Loopback restriction: `NWListener` listens on all interfaces by
/// default, so the bind host is pinned via
/// `NWParameters.requiredLocalEndpoint`. A `127.0.0.1` config therefore
/// binds loopback-only — the security default the guard depends on.
public final class OpenAIListener: @unchecked Sendable {

    public struct Config: Sendable {
        /// Bind host. Default `127.0.0.1`.
        public var bind: String
        /// Bind port. 0 = kernel-assigned (read back after `.ready`).
        public var port: Int

        public init(bind: String = "127.0.0.1", port: Int = 8470) {
            self.bind = bind
            self.port = port
        }
    }

    public enum ListenError: Error, Equatable {
        case invalidPort(Int)
        case startTimeout
        case nwFailed(String)
    }

    private let config: Config
    private let queue = DispatchQueue(label: "com.senkani.openai-listener", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: Int = 0
    private var running = false

    public init(config: Config) {
        self.config = config
    }

    /// Bound port after `start()` succeeds. Zero before start / after stop.
    public var port: Int {
        lock.lock(); defer { lock.unlock() }
        return boundPort
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Bind, start accepting, and block (bounded) until the listener is
    /// ready. Throws on invalid port or `NWListener` failure.
    public func start() throws {
        lock.lock()
        if running { lock.unlock(); return }
        lock.unlock()

        guard config.port >= 0, config.port <= 65535 else {
            throw ListenError.invalidPort(config.port)
        }
        let nwPort: NWEndpoint.Port = config.port == 0
            ? .any
            : (NWEndpoint.Port(rawValue: UInt16(config.port)) ?? .any)

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Pin the local endpoint so a loopback bind stays loopback-only.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(config.bind),
            port: nwPort
        )

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw ListenError.nwFailed("\(error)")
        }

        let ready = DispatchSemaphore(value: 0)
        let errBox = ErrorBox()
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let raw = listener.port?.rawValue {
                    self?.setBoundPort(Int(raw))
                }
                ready.signal()
            case .failed(let err):
                errBox.set(err)
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw ListenError.startTimeout
        }
        if let err = errBox.get() {
            listener.cancel()
            throw ListenError.nwFailed("\(err)")
        }

        lock.lock()
        self.listener = listener
        self.running = true
        lock.unlock()
    }

    /// Cancel the listener and release the port. Idempotent.
    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let l = listener
        listener = nil
        boundPort = 0
        lock.unlock()
        l?.cancel()
    }

    private func setBoundPort(_ p: Int) {
        lock.lock(); boundPort = p; lock.unlock()
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                OpenAIListener.receiveRequest(conn)
            case .failed, .cancelled:
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private static func receiveRequest(_ conn: NWConnection) {
        // The request line + headers arrive in the first segment for the
        // small GETs this scaffold serves; the body is irrelevant to the
        // 501 stub, so a single bounded receive is sufficient.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
            if error != nil {
                conn.cancel()
                return
            }
            let requestLine = OpenAIListener.firstLine(data ?? Data())
            let response = OpenAIListener.route(requestLine: requestLine)
            conn.send(content: response, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }

    // MARK: - Routing (pure, testable)

    /// Extract the first CRLF/LF-terminated line from the request bytes.
    static func firstLine(_ data: Data) -> String {
        guard let idx = data.firstIndex(of: 0x0A) else {
            return String(decoding: data, as: UTF8.self)
        }
        let line = data[data.startIndex..<idx]
        return String(decoding: line, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
    }

    /// Route a request line to a canned HTTP/1.1 response. In v13a-1
    /// every `/v1/*` path is `501 Not Implemented` (no surface wired
    /// yet); anything else is `404 Not Found`.
    static func route(requestLine: String) -> Data {
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        let path = parts.count >= 2 ? String(parts[1]) : "/"
        if path == "/v1" || path.hasPrefix("/v1/") {
            return httpResponse(
                code: 501, message: "Not Implemented",
                body: "{\"error\":{\"message\":\"not implemented yet (v13a-1 listener scaffold)\","
                    + "\"type\":\"not_implemented\"}}"
            )
        }
        return httpResponse(
            code: 404, message: "Not Found",
            body: "{\"error\":{\"message\":\"unknown path\",\"type\":\"not_found\"}}"
        )
    }

    /// Build a well-formed HTTP/1.1 response with `Content-Length` and
    /// `Connection: close`.
    static func httpResponse(code: Int, message: String, body: String) -> Data {
        let bodyData = Data(body.utf8)
        var head = "HTTP/1.1 \(code) \(message)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(bodyData)
        return out
    }

    /// One-line startup summary: resolved bind + port + key-count.
    public static func startupLog(bind: String, port: Int, keyCount: Int) -> String {
        "senkani serve --openai listening on \(bind):\(port) — \(keyCount) provisioned key(s)"
    }

    /// Thread-safe box so the `stateUpdateHandler` closure can hand a
    /// failure back to `start()` across the dispatch queue boundary.
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?
        func set(_ e: Error) { lock.lock(); error = e; lock.unlock() }
        func get() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
    }
}
#endif
