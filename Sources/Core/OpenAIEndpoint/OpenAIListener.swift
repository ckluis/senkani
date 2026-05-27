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

    /// V.13a-2 — bearer-auth binding for a request. Wrapping the pure
    /// `OpenAIAuthGate` lets `ServeCommand` capture the vault snapshot +
    /// rate limiter while keeping the listener platform-agnostic. When
    /// the listener has no authenticator (the v13a-1 scaffold contract,
    /// and the existing scaffold tests), every `/v1/*` request falls
    /// straight through to the `501` stub.
    public struct Authenticator: Sendable {
        public let decide: @Sendable (_ method: String, _ path: String, _ headers: [String: String]) -> OpenAIAuthGate.Decision

        public init(decide: @escaping @Sendable (_ method: String, _ path: String, _ headers: [String: String]) -> OpenAIAuthGate.Decision) {
            self.decide = decide
        }
    }

    /// V.13a-3 — surface handler invoked AFTER the auth gate admits a
    /// `/v1/*` request. Receives the parsed request line, headers, and the
    /// request body. Returns a framed HTTP response, or nil to fall
    /// through to the `501`/`404` `route` (the v13a-1/2 behavior when no
    /// handler is wired). `ServeCommand` builds the chat handler; the
    /// scaffold tests leave it nil.
    public struct ChatHandler: Sendable {
        public let handle: @Sendable (_ method: String, _ path: String, _ headers: [String: String], _ body: Data) -> Data?

        public init(handle: @escaping @Sendable (_ method: String, _ path: String, _ headers: [String: String], _ body: Data) -> Data?) {
            self.handle = handle
        }
    }

    public enum ListenError: Error, Equatable {
        case invalidPort(Int)
        case startTimeout
        case nwFailed(String)
    }

    private let config: Config
    private let authenticator: Authenticator?
    private let chatHandler: ChatHandler?
    private let queue = DispatchQueue(label: "com.senkani.openai-listener", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: Int = 0
    private var running = false

    /// Cap on accumulated request bytes (head + body). A request larger
    /// than this is responded to with whatever was read — protects against
    /// an unbounded body on the accept queue.
    static let maxRequestBytes = 256 * 1024

    public init(config: Config, authenticator: Authenticator? = nil, chatHandler: ChatHandler? = nil) {
        self.config = config
        self.authenticator = authenticator
        self.chatHandler = chatHandler
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
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveRequest(conn, accumulated: Data())
            case .failed, .cancelled:
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    /// Read the request, accumulating segments until the full body (per
    /// `Content-Length`) has arrived, the peer signals completion, or the
    /// byte cap is hit. v13a-1/2 needed only the head; v13a-3's chat
    /// surface needs the body, which may span more than one segment.
    private func receiveRequest(_ conn: NWConnection, accumulated: Data) {
        let authenticator = self.authenticator
        let chatHandler = self.chatHandler
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if error != nil {
                conn.cancel()
                return
            }
            var buf = accumulated
            if let data { buf.append(data) }

            let done = isComplete
                || buf.count >= OpenAIListener.maxRequestBytes
                || OpenAIListener.requestComplete(buf)
            if !done {
                self?.receiveRequest(conn, accumulated: buf)
                return
            }

            let response = OpenAIListener.respond(
                requestLine: OpenAIListener.firstLine(buf),
                headers: OpenAIListener.parseHeaders(buf),
                body: OpenAIListener.bodyBytes(buf),
                authenticator: authenticator,
                chatHandler: chatHandler
            )
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

    /// Parse request headers into a lower-cased-name → value map. Stops
    /// at the first blank line (the head/body boundary). Header names are
    /// case-insensitive per RFC 7230, so they are normalized to lower
    /// case for lookup (`headers["authorization"]`).
    static func parseHeaders(_ data: Data) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        var headers: [String: String] = [:]
        var isFirst = true
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if isFirst { isFirst = false; continue }   // skip the request line
            if line.isEmpty { break }                  // end of headers
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers[name] = value }
        }
        return headers
    }

    /// Split a request line into `(method, path)`. Pure helper.
    static func methodAndPath(_ requestLine: String) -> (method: String, path: String) {
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        let method = parts.count >= 1 ? String(parts[0]) : "GET"
        let path = parts.count >= 2 ? String(parts[1]) : "/"
        return (method, path)
    }

    /// V.13a-2 — full request resolution: apply the auth gate (when an
    /// authenticator is configured) on the `/v1/*` prefix BEFORE the
    /// surface routing, then fall through to `route` for the 501 stub /
    /// 404. When the decision is non-`ok` the gate's error response
    /// (401 / 403 / 429 + Retry-After) is returned and `route` is never
    /// reached — auth is enforced ahead of the surface. Pure + testable.
    static func respond(
        requestLine: String,
        headers: [String: String],
        body: Data = Data(),
        authenticator: Authenticator?,
        chatHandler: ChatHandler? = nil
    ) -> Data {
        let (method, path) = methodAndPath(requestLine)
        if let authenticator {
            // Only the `/v1/*` surface is auth-gated; other paths (e.g. a
            // future health probe) fall straight through.
            if path == "/v1" || path.hasPrefix("/v1/") {
                let decision = authenticator.decide(method, path, headers)
                if let errorResponse = OpenAIAuthGate.errorResponse(for: decision) {
                    return errorResponse
                }
            }
        }
        // V.13a-3 — auth has admitted the request; dispatch the chat
        // surface. A nil return (handler not wired, or path/method it does
        // not serve) falls through to the 501/404 route.
        if let chatHandler,
           method.uppercased() == "POST",
           path == "/v1/chat/completions" {
            if let surfaceResponse = chatHandler.handle(method, path, headers, body) {
                return surfaceResponse
            }
        }
        return route(requestLine: requestLine)
    }

    // MARK: - Body framing (pure, testable)

    /// Byte offset just past the `\r\n\r\n` head/body boundary, or nil if
    /// the boundary has not been received yet.
    static func headBodyBoundary(_ data: Data) -> Int? {
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = data.range(of: sep) else { return nil }
        return data.distance(from: data.startIndex, to: range.upperBound)
    }

    /// Body bytes (everything past the head/body boundary). Empty if the
    /// boundary is absent.
    static func bodyBytes(_ data: Data) -> Data {
        guard let boundary = headBodyBoundary(data) else { return Data() }
        return Data(data.dropFirst(boundary))
    }

    /// True once the head boundary is present AND at least `Content-Length`
    /// body bytes have arrived (0 when the header is absent). Drives the
    /// accumulation loop in `receiveRequest`.
    static func requestComplete(_ data: Data) -> Bool {
        guard let boundary = headBodyBoundary(data) else { return false }
        let contentLength = parseHeaders(data)["content-length"].flatMap { Int($0) } ?? 0
        let bodyLen = data.count - boundary
        return bodyLen >= contentLength
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
    /// `Connection: close`. Delegates to the shared, Network-agnostic
    /// `OpenAIHTTPResponse` builder so the auth path and the surface path
    /// emit byte-identical framing.
    static func httpResponse(code: Int, message: String, body: String) -> Data {
        OpenAIHTTPResponse.render(code: code, message: message, body: body)
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
