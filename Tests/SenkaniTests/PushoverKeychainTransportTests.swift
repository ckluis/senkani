import Testing
import Foundation
@testable import Core

/// Coverage for `phase-t6c-keychain-transport-2026-06-09` (T.6c sibling
/// carve B) — the REAL Keychain-reading `KeychainPushoverTransport`,
/// tested entirely against injectable seams:
///   * Keychain = `InMemoryKeychainStore`-backed `CredentialVault`
///     (the REAL login Keychain is never touched),
///   * HTTP = `MockPushoverHTTPClient` (the network is never touched),
///   * credential = a FAKE `token:user` string (no real secret exists
///     anywhere in this file).
///
/// The suite is `.serialized` because three tests drive the sink's
/// synchronous `notify(_:)` through the transport's balanced-semaphore
/// bridge — serializing keeps at most ONE blocked waiter at a time so
/// the cooperative pool can always make progress (the documented
/// pool-starvation reflex).
@Suite("T.6c child B — KeychainPushoverTransport (Keychain read + mock HTTP)", .serialized)
struct PushoverKeychainTransportTests {

    // MARK: - Mock HTTP seam (records every post; scripts status / throw)

    final class MockPushoverHTTPClient: PushoverHTTPClient, @unchecked Sendable {
        enum Mode {
            case status(Int)
            case throwError
        }
        struct InjectedError: Error {}

        private let lock = NSLock()
        private var _posts: [PushoverHTTPPost] = []
        private let mode: Mode

        init(mode: Mode = .status(200)) {
            self.mode = mode
        }

        var posts: [PushoverHTTPPost] {
            lock.lock()
            defer { lock.unlock() }
            return _posts
        }

        /// Synchronous record helper — `NSLock.lock()` is unavailable
        /// directly inside an async function body.
        private func record(_ request: PushoverHTTPPost) {
            lock.lock()
            _posts.append(request)
            lock.unlock()
        }

        func post(_ request: PushoverHTTPPost) async throws -> Int {
            record(request)
            switch mode {
            case .status(let code): return code
            case .throwError: throw InjectedError()
            }
        }
    }

    /// A hermetic vault. `credential: nil` ⇒ the canonical slot is EMPTY
    /// (the missing-seed scenario); otherwise the fake credential is
    /// seeded under exactly the slot `doctor --seed-pushover-key` writes.
    static func makeVault(credential: String?) async throws -> CredentialVault {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        if let credential {
            try await vault.write(
                key: PushoverCredentialsRef.vaultKey,
                scope: PushoverCredentialsRef.vaultScope,
                value: Data(credential.utf8)
            )
        }
        return vault
    }

    static let fakeCredential = "fake-app-token:fake-user-key"

    // MARK: - Acceptance 1+2: happy POST shape through the full sink path

    @Test("Happy path: sink → transport resolves the seeded slot and POSTs the right shape (url, token, user, body, priority)")
    func happyPostShape() async throws {
        let vault = try await Self.makeVault(credential: Self.fakeCredential)
        let http = MockPushoverHTTPClient(mode: .status(200))
        let transport = KeychainPushoverTransport(vault: vault, httpClient: http)
        let telemetry = SpyPushoverDeliveryTelemetry()
        // Default-initialized ref points at the seeded canonical slot.
        let sink = PushoverSink(
            credentials: PushoverCredentialsRef(),
            transport: transport,
            telemetry: telemetry
        )

        try sink.notify(.notifyFailure(toolName: "Bash", reason: "exit 1"))

        #expect(http.posts.count == 1)
        let post = try #require(http.posts.first)
        // URL is the pinned host + messages path — never request-derived.
        #expect(post.url.absoluteString == "https://api.pushover.net/1/messages.json")
        // Token NAME resolved through the vault: the fields carry the
        // credential that was seeded under `senkani.pushover`.
        #expect(post.formFields["token"] == "fake-app-token")
        #expect(post.formFields["user"] == "fake-user-key")
        // Body = the minimized message; failure events push high priority.
        #expect(post.formFields["message"] == "[Bash] exit 1")
        #expect(post.formFields["title"] == "Senkani — notify_failure")
        #expect(post.formFields["priority"] == "1")
        // Success heartbeat recorded at the fan-out.
        #expect(telemetry.records.count == 1)
        #expect(try #require(telemetry.records.first).outcome == .delivered)
    }

    // MARK: - Acceptance 2: missing key ⇒ clean no-op degrade

    @Test("Missing seed: sink degrades cleanly — no crash, no throw, HTTP never touched, one observable unconfigured row")
    func missingKeyDegradesCleanly() async throws {
        let vault = try await Self.makeVault(credential: nil) // slot EMPTY
        let http = MockPushoverHTTPClient(mode: .status(200))
        let transport = KeychainPushoverTransport(vault: vault, httpClient: http)
        let telemetry = SpyPushoverDeliveryTelemetry()
        let sink = PushoverSink(
            credentials: PushoverCredentialsRef(),
            transport: transport,
            telemetry: telemetry
        )

        // MUST NOT throw, hang, or crash — the missing seed is swallowed.
        try sink.notify(.notifyDone(toolName: "Edit", summary: "ok"))

        // The HTTP client was NEVER called — the vault read failed first.
        #expect(http.posts.isEmpty,
                "A missing seed must degrade BEFORE the HTTP client runs.")
        // Exactly one observable row, mapped to the operator-meaningful
        // reason: "no token seeded yet", not "the network failed".
        #expect(telemetry.records.count == 1)
        let row = try #require(telemetry.records.first)
        #expect(row.outcome == .deliveryFailed)
        #expect(row.reason == .unconfigured)
    }

    // MARK: - Acceptance 3: HTTP failure swallow

    @Test("HTTP throw: the failure is swallowed into exactly one delivery_failed(transport_error) row — the agent is never blocked")
    func httpFailureIsSwallowed() async throws {
        let vault = try await Self.makeVault(credential: Self.fakeCredential)
        let http = MockPushoverHTTPClient(mode: .throwError)
        let transport = KeychainPushoverTransport(vault: vault, httpClient: http)
        let telemetry = SpyPushoverDeliveryTelemetry()
        let sink = PushoverSink(
            credentials: PushoverCredentialsRef(),
            transport: transport,
            telemetry: telemetry
        )

        // MUST NOT throw past the sink (the T.6a non-blocking contract).
        try sink.notify(.scheduleEnd(scheduleId: "nightly", summary: "done"))

        // The POST was attempted, then the throw was swallowed.
        #expect(http.posts.count == 1)
        #expect(telemetry.records.count == 1)
        let row = try #require(telemetry.records.first)
        #expect(row.outcome == .deliveryFailed)
        #expect(row.reason == .transportError)
    }

    @Test("Non-2xx status: a 500 from the API is a transport error — swallowed, observable, never delivered")
    func nonSuccessStatusIsTransportError() async throws {
        let vault = try await Self.makeVault(credential: Self.fakeCredential)
        let http = MockPushoverHTTPClient(mode: .status(500))
        let transport = KeychainPushoverTransport(vault: vault, httpClient: http)
        let telemetry = SpyPushoverDeliveryTelemetry()
        let sink = PushoverSink(
            credentials: PushoverCredentialsRef(),
            transport: transport,
            telemetry: telemetry
        )

        try sink.notify(.notifyDone(toolName: "Write", summary: "wrote"))

        #expect(http.posts.count == 1)
        #expect(telemetry.records.count == 1)
        let row = try #require(telemetry.records.first)
        #expect(row.outcome == .deliveryFailed)
        #expect(row.reason == .transportError)
    }

    // MARK: - Direct async-motion contracts (no bridge, plain await)

    @Test("Malformed credential (no token:user separator) throws a payload-free error BEFORE the HTTP client runs")
    func malformedCredentialDegrades() async throws {
        let vault = try await Self.makeVault(credential: "no-separator-here")
        let http = MockPushoverHTTPClient(mode: .status(200))
        let transport = KeychainPushoverTransport(vault: vault, httpClient: http)
        let request = PushoverRequest(
            host: PushoverSink.host,
            path: PushoverSink.path,
            message: PushoverMessage(event: .notifyDone(toolName: "Edit", summary: "ok"))
        )

        await #expect(throws: PushoverTransportError.malformedCredential) {
            try await transport.sendAsync(request)
        }
        #expect(http.posts.isEmpty,
                "A malformed credential must fail BEFORE any POST.")
        // Empty halves are malformed too.
        #expect(throws: PushoverTransportError.malformedCredential) {
            _ = try KeychainPushoverTransport.parseCredential(":user-only")
        }
        #expect(throws: PushoverTransportError.malformedCredential) {
            _ = try KeychainPushoverTransport.parseCredential("token-only:")
        }
    }

    @Test("Defense-in-depth host pin: a foreign-host request is refused before the vault or HTTP client are touched")
    func foreignHostIsRefused() async throws {
        let vault = try await Self.makeVault(credential: Self.fakeCredential)
        let http = MockPushoverHTTPClient(mode: .status(200))
        let transport = KeychainPushoverTransport(vault: vault, httpClient: http)
        let request = PushoverRequest(
            host: "evil.example.com",
            path: PushoverSink.path,
            message: PushoverMessage(event: .notifyDone(toolName: "Edit", summary: "ok"))
        )

        await #expect(throws: PushoverTransportError.unexpectedHost("evil.example.com")) {
            try await transport.sendAsync(request)
        }
        #expect(http.posts.isEmpty)
    }

    // MARK: - Pure helpers (deterministic, no seams)

    @Test("Priority derives from the stable event class: failures push 1, done/schedule push 0")
    func priorityDerivation() {
        let failure = PushoverMessage(event: .notifyFailure(toolName: "Bash", reason: "x"))
        let done = PushoverMessage(event: .notifyDone(toolName: "Edit", summary: "x"))
        let schedule = PushoverMessage(event: .scheduleEnd(scheduleId: "s", summary: "x"))
        #expect(KeychainPushoverTransport.priority(for: failure) == "1")
        #expect(KeychainPushoverTransport.priority(for: done) == "0")
        #expect(KeychainPushoverTransport.priority(for: schedule) == "0")
        // The fields builder carries the derived priority + only
        // minimized message fields + the credential halves.
        let fields = KeychainPushoverTransport.formFields(message: done, token: "t", user: "u")
        #expect(fields["priority"] == "0")
        #expect(fields["token"] == "t")
        #expect(fields["user"] == "u")
        #expect(Set(fields.keys) == ["token", "user", "title", "message", "priority"])
    }

    @Test("URLSession client form encoding is deterministic (sorted keys) and escapes framing characters")
    func formEncodingIsDeterministicAndEscaped() {
        let encoded = URLSessionPushoverHTTPClient.formEncode([
            "user": "u-key",
            "message": "a&b=c d+e",
            "token": "t-key",
        ])
        // Sorted by key: message, token, user — byte-stable across runs.
        #expect(encoded == "message=a%26b%3Dc%20d%2Be&token=t-key&user=u-key")
    }
}
