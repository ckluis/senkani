import Foundation

/// Phase T.6c sibling carve B — `KeychainPushoverTransport`
/// (`phase-t6c-keychain-transport-2026-06-09`).
///
/// The REAL `PushoverTransport`: at send time it resolves the
/// operator-seeded credential from the Keychain seam (`CredentialVault`
/// over `KeychainStore`) under the canonical slot
/// `PushoverCredentialsRef.vaultKey` / `.vaultScope` — exactly the slot
/// `senkani doctor --seed-pushover-key` (T.6c sibling carve A) writes —
/// then form-POSTs the already-minimized `PushoverMessage` through an
/// injectable `PushoverHTTPClient`.
///
/// ## What is and is NOT in the autonomous build
/// Everything here compiles and tests WITHOUT a real token and WITHOUT
/// any network: tests inject an `InMemoryKeychainStore`-backed vault and
/// a mock `PushoverHTTPClient`. The production
/// `URLSessionPushoverHTTPClient` ships below but is exercised only by
/// the operator leg C of the parent item
/// (`phase-t6c-1-pushover-seed-operator`): seed the REAL token, wire the
/// transport into SenkaniApp's notification bootstrap, edit the
/// egress policy, prove a live device push.
///
/// ## Security posture (Schneier / Cavoukian)
///   * **Host pin (defense-in-depth).** The sink already gates egress
///     through its `EgressRuleEngine`; this transport ADDITIONALLY
///     refuses any `PushoverRequest` whose host is not the compile-time
///     constant `PushoverSink.host` — there is no code path by which it
///     POSTs anywhere but `api.pushover.net`.
///   * **The secret never escapes the send path.** The credential is
///     read at send time, split into `token` + `user`, placed ONLY on
///     the outgoing form fields, and dropped. No error case carries the
///     credential (every `PushoverTransportError` payload is a host
///     string or a status code), nothing is logged, and the
///     `PushoverRequest`/`PushoverMessage` types remain secret-free.
///   * **Missing seed degrades cleanly.** No seeded credential ⇒ the
///     vault read throws `CredentialVaultError.missingKey` BEFORE the
///     HTTP client is ever touched; the sink swallows it and records an
///     observable `delivery_failed(unconfigured)` telemetry row
///     (Majors: a silent drop is never invisible). The agent is never
///     blocked and never crashes.
///   * **Body is already minimized.** The transport only ever sees a
///     `PushoverMessage` (Gate 3: secret-scrubbed, newline-collapsed,
///     length-capped at construction) — it adds the credential fields
///     and the derived priority, nothing else.
public struct KeychainPushoverTransport: PushoverTransport {

    private let vault: CredentialVault
    private let httpClient: any PushoverHTTPClient
    private let key: String
    private let scope: String
    private let sendWaitCeiling: TimeInterval

    /// Build the Keychain-reading transport.
    ///
    /// - Parameters:
    ///   - vault: the credential vault to resolve the seeded credential
    ///     from. Defaults to `CredentialVault.shared`; tests inject an
    ///     `InMemoryKeychainStore`-backed vault.
    ///   - httpClient: the HTTP seam. Production injects
    ///     `URLSessionPushoverHTTPClient`; tests inject a mock — the
    ///     autonomous build never touches the network.
    ///   - key: the vault key NAME to read. Defaults to the canonical
    ///     `PushoverCredentialsRef.vaultKey` (`senkani.pushover`).
    ///   - scope: the vault scope. Defaults to
    ///     `PushoverCredentialsRef.vaultScope`.
    ///   - sendWaitCeiling: wall-clock ceiling (seconds) on the
    ///     synchronous `send(_:)` bridge — a hung network must not block
    ///     the agent forever (Allspaw). The underlying HTTP client keeps
    ///     its own (shorter) request timeout; this is the outer fuse.
    public init(
        vault: CredentialVault = .shared,
        httpClient: any PushoverHTTPClient,
        key: String = PushoverCredentialsRef.vaultKey,
        scope: String = PushoverCredentialsRef.vaultScope,
        sendWaitCeiling: TimeInterval = 30
    ) {
        self.vault = vault
        self.httpClient = httpClient
        self.key = key
        self.scope = scope
        self.sendWaitCeiling = sendWaitCeiling
    }

    // MARK: - PushoverTransport (synchronous seam the sink calls)

    /// Synchronous bridge onto the async send motion (the sink's
    /// `notify(_:)` is synchronous). Balanced-semaphore pattern
    /// (`Doctor.runSeedPushoverKey` / `vaultRoundTrip` mirror): the Task
    /// ALWAYS `signal()`s via `defer`, and the wait carries the
    /// `sendWaitCeiling` fuse so a wedged network surfaces as a thrown
    /// `PushoverTransportError.timedOut` — which the sink swallows into
    /// a `delivery_failed(transport_error)` row per its non-blocking
    /// contract.
    ///
    /// COOPERATIVE-POOL SAFETY (the phase-t1d-6 lesson, `ServeBridge`
    /// mirror): on macOS 15+ the motion Task is hosted on a DEDICATED
    /// `TaskExecutor` whose threads are outside Swift Concurrency's
    /// cooperative pool. Without this, a caller blocking a cooperative
    /// thread in this very `wait()` competes with the inner Task for the
    /// same pool — under `swift test`'s parallel load the motion can
    /// starve past the fuse (observed: the first full-suite run timed
    /// out exactly here). The dedicated executor guarantees the motion
    /// STARTS regardless of pool saturation.
    public func send(_ request: PushoverRequest) throws {
        final class Slot: @unchecked Sendable {
            private let lock = NSLock()
            private var _value: Result<Void, Error>?
            func publish(_ v: Result<Void, Error>) {
                lock.lock(); defer { lock.unlock() }; _value = v
            }
            func snapshot() -> Result<Void, Error>? {
                lock.lock(); defer { lock.unlock() }; return _value
            }
        }
        let slot = Slot()
        let sem = DispatchSemaphore(value: 0)
        let transport = self
        let motion: @Sendable () async -> Void = {
            defer { sem.signal() }
            do {
                try await transport.sendAsync(request)
                slot.publish(.success(()))
            } catch {
                slot.publish(.failure(error))
            }
        }
        if #available(macOS 15.0, *) {
            Task(executorPreference: PushoverSendBridge.executor, operation: motion)
        } else {
            // macOS-14 floor: SE-0417 unavailable — the pre-fix
            // cooperative-pool spawn. Production v14 callers block a
            // non-cooperative thread, so self-starvation cannot occur
            // there; tests run on the macOS 15+ toolchain.
            Task(operation: motion)
        }
        guard sem.wait(timeout: .now() + sendWaitCeiling) == .success else {
            // The abandoned Task finishes (or times out) on its own; the
            // agent moves on NOW.
            throw PushoverTransportError.timedOut
        }
        switch slot.snapshot() {
        case .success:
            return
        case .failure(let error):
            throw error
        case nil:
            throw PushoverTransportError.timedOut
        }
    }

    // MARK: - The async send motion (testable without the bridge)

    /// The full send motion: host pin → vault read → credential parse →
    /// form-POST → status check. Every failure throws (the sink's
    /// swallow-site records it); the HTTP client is touched ONLY after
    /// the credential resolved and parsed.
    public func sendAsync(_ request: PushoverRequest) async throws {
        // Defense-in-depth host pin — the sink's egress gate already ran,
        // but this transport refuses to POST anywhere but the constant.
        guard request.host == PushoverSink.host else {
            throw PushoverTransportError.unexpectedHost(request.host)
        }

        // Resolve the operator-seeded credential at send time. A missing
        // seed throws CredentialVaultError.missingKey HERE — the HTTP
        // client below is never reached.
        let raw = try await vault.read(key: key, scope: scope)
        let credential = String(decoding: raw, as: UTF8.self)
        let (token, user) = try Self.parseCredential(credential)

        var components = URLComponents()
        components.scheme = "https"
        components.host = PushoverSink.host // pinned, never request-derived
        components.path = request.path
        guard let url = components.url else {
            throw PushoverTransportError.malformedRequestURL
        }

        let post = PushoverHTTPPost(
            url: url,
            formFields: Self.formFields(message: request.message, token: token, user: user)
        )
        let status = try await httpClient.post(post)
        guard (200..<300).contains(status) else {
            throw PushoverTransportError.nonSuccessStatus(status)
        }
    }

    // MARK: - Pure helpers (deterministic, secret-shape aware)

    /// Parse the seeded credential into `(token, user)`.
    ///
    /// The seed format is `<app-token>:<user-key>` — ONE pasted string,
    /// split on the FIRST colon (Pushover token/user keys are
    /// colon-free; splitting on the first keeps the parse total). A
    /// missing colon or an empty half throws `malformedCredential` —
    /// an enum case with NO payload, so the secret cannot ride out on
    /// the error.
    static func parseCredential(_ raw: String) throws -> (token: String, user: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = trimmed.firstIndex(of: ":") else {
            throw PushoverTransportError.malformedCredential
        }
        let token = String(trimmed[..<idx])
        let user = String(trimmed[trimmed.index(after: idx)...])
        guard !token.isEmpty, !user.isEmpty else {
            throw PushoverTransportError.malformedCredential
        }
        return (token, user)
    }

    /// Build the Pushover form fields. Every body-bearing value comes
    /// from the already-minimized `PushoverMessage` (Gate 3); the
    /// credential halves are added here and ONLY here.
    static func formFields(
        message: PushoverMessage,
        token: String,
        user: String
    ) -> [String: String] {
        [
            "token": token,
            "user": user,
            "title": "Senkani — \(message.eventClass)",
            "message": "[\(message.primaryId)] \(message.template)",
            "priority": Self.priority(for: message),
        ]
    }

    /// Pushover priority derivation: failures push high (`1`), everything
    /// else normal (`0`). Derived from the stable event-class string —
    /// never from free-form body text.
    static func priority(for message: PushoverMessage) -> String {
        message.eventClass == "notify_failure" ? "1" : "0"
    }
}

/// Process-wide dedicated executor for the Pushover send bridge — the
/// `ServeBridge.executor` mirror. Sends are low-frequency (one per
/// notified event), so a single shared dedicated queue is plenty.
@available(macOS 15.0, *)
private enum PushoverSendBridge {
    static let executor = DedicatedThreadTaskExecutor(label: "senkani.pushover-send")
}

// MARK: - Error surface (NO payload shape can carry the secret)

/// Errors the Keychain-reading transport throws. Every associated value
/// is a host string or an HTTP status code — there is no case shape by
/// which the credential could reach a log line (Schneier).
public enum PushoverTransportError: Error, Equatable, Sendable {
    /// Defense-in-depth host pin tripped — the request named a host
    /// other than `PushoverSink.host`. Should be unreachable behind the
    /// sink's egress gate.
    case unexpectedHost(String)
    /// The seeded credential did not parse as `<app-token>:<user-key>`.
    /// Carries NO payload — the secret cannot ride out on the error.
    case malformedCredential
    /// URL assembly failed (should be unreachable for the pinned
    /// host + constant path).
    case malformedRequestURL
    /// The POST completed with a non-2xx status.
    case nonSuccessStatus(Int)
    /// The synchronous `send(_:)` bridge hit its wall-clock ceiling —
    /// the agent moves on rather than blocking on a wedged network.
    case timedOut
}

// MARK: - HTTP seam (mock-tested; URLSession conformance for leg C)

/// One form-POST the transport hands to the HTTP seam: the pinned URL +
/// the flat form fields (token, user, title, message, priority). The
/// mock client records these for shape assertions; the URLSession client
/// percent-encodes and sends them.
public struct PushoverHTTPPost: Sendable, Equatable {
    public let url: URL
    public let formFields: [String: String]

    public init(url: URL, formFields: [String: String]) {
        self.url = url
        self.formFields = formFields
    }
}

/// The injectable HTTP client seam. Tests inject a mock (records posts,
/// scripts the status / a throw); production injects
/// `URLSessionPushoverHTTPClient`. Returns the HTTP status code; throws
/// on connection-level failure.
public protocol PushoverHTTPClient: Sendable {
    func post(_ request: PushoverHTTPPost) async throws -> Int
}

/// Production conformance: a real `application/x-www-form-urlencoded`
/// POST via URLSession. NOT exercised by any test (no network in the
/// autonomous build) — operator leg C of the parent T.6c item proves it
/// against the live `api.pushover.net`.
public struct URLSessionPushoverHTTPClient: PushoverHTTPClient {
    private let session: URLSession
    private let requestTimeout: TimeInterval

    public init(session: URLSession = .shared, requestTimeout: TimeInterval = 15) {
        self.session = session
        self.requestTimeout = requestTimeout
    }

    public func post(_ request: PushoverHTTPPost) async throws -> Int {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = requestTimeout
        urlRequest.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        urlRequest.httpBody = Data(Self.formEncode(request.formFields).utf8)
        let (_, response) = try await session.data(for: urlRequest)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// Deterministic (sorted-key) form encoding with strict
    /// percent-escaping (unreserved characters only — RFC 3986
    /// alphanumerics + `-._~`), so a credential or template containing
    /// `&`, `=`, `+`, or unicode cannot break field framing.
    static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}
