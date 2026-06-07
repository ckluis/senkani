import Testing
import Foundation
@testable import Core

#if canImport(Darwin)
import Darwin
#endif

/// V.13a-2 — bearer auth + CredentialVault key provisioning + per-key
/// rate-limit + scope + expiry. Covers the acceptance checklist from
/// `spec/autonomous/backlog/phase-v13a-2-bearer-auth-vault.md`:
///
///   1. provision + print-once + hash-only
///   2. missing-auth → 401
///   3. malformed-auth → 401
///   4. unknown-key → 401
///   5. constant-time, no oracle between "no such key" and "wrong key"
///   6. out-of-scope → 403
///   7. over-rate → 429 + Retry-After
///   8. expired → 401
///   9. default 60 rpm
///  10. vault-record override rpm
///  +  auth enforced on /v1/* BEFORE the 501 stub
@Suite("OpenAI endpoint bearer auth (V.13a-2)")
struct OpenAIAuthGateTests {

    // A throwaway record with a known plaintext key.
    private static func record(
        forKey key: String,
        scope: [String] = ["chat", "embeddings"],
        rateLimit: Int = OpenAIKeyRecord.defaultRateLimit,
        expiresAt: Date? = nil,
        label: String? = "test"
    ) -> OpenAIKeyRecord {
        OpenAIKeyRecord(
            keyHash: OpenAIAuthGate.hash(key),
            preset: "openai",
            scope: scope,
            rateLimit: rateLimit,
            createdAt: Date(timeIntervalSince1970: 0),
            expiresAt: expiresAt,
            label: label
        )
    }

    private func bearer(_ key: String) -> String { "Bearer \(key)" }

    // MARK: - 1. provision + print-once + hash-only

    @Test("provision generates an sk-senkani key and stores hash-only in the vault")
    func provisionStoresHashOnly() async throws {
        let path = NSTemporaryDirectory() + "v13a-2-vault-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let provisioned = OpenAIKeyProvisioner.provision(
            preset: "openai", scope: ["chat"], rateLimit: 60,
            expiresAt: nil, label: "ci", now: Date()
        )
        #expect(provisioned.plaintextKey.hasPrefix("sk-senkani-"))
        #expect(provisioned.record.keyHash == OpenAIAuthGate.hash(provisioned.plaintextKey))
        // The record carries the hash, never the plaintext.
        #expect(provisioned.record.keyHash != provisioned.plaintextKey)

        let vault = OpenAIKeyProvisioner.vault(path: path)
        try await OpenAIKeyProvisioner.store(provisioned.record, vault: vault)

        // The persisted file contains the hash but NOT the plaintext key.
        let raw = try #require(FileManager.default.contents(atPath: path))
        let onDisk = String(decoding: raw, as: UTF8.self)
        #expect(onDisk.contains(provisioned.record.keyHash))
        #expect(!onDisk.contains(provisioned.plaintextKey))

        // The file is 0600 (owner-only) — the verifier is not world-readable.
        #if canImport(Darwin)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = try #require(attrs[.posixPermissions] as? NSNumber)
        #expect((perms.uint16Value & 0o177) == 0)
        #endif

        // Round-trips back through the vault.
        let loaded = try await OpenAIKeyProvisioner.loadAll(vault: vault)
        #expect(loaded.count == 1)
        #expect(loaded.first?.keyHash == provisioned.record.keyHash)
        #expect(loaded.first?.scope == ["chat"])
    }

    // MARK: - 2. missing auth → 401

    @Test("missing Authorization header → 401")
    func missingAuth401() {
        let decision = OpenAIAuthGate.decide(
            authorizationHeader: nil, requestedSurface: "chat",
            now: Date(), records: [], rateLimiter: OpenAIRateLimiter()
        )
        guard case .unauthorized = decision else { Issue.record("expected 401, got \(decision)"); return }
    }

    // MARK: - 3. malformed auth → 401

    @Test("malformed Authorization header → 401")
    func malformedAuth401() {
        let limiter = OpenAIRateLimiter()
        for header in ["", "Token abc", "Bearer", "Bearer    ", "Basic dXNlcjpwYXNz"] {
            let decision = OpenAIAuthGate.decide(
                authorizationHeader: header, requestedSurface: "chat",
                now: Date(), records: [], rateLimiter: limiter
            )
            guard case .unauthorized = decision else {
                Issue.record("expected 401 for header '\(header)', got \(decision)"); continue
            }
        }
        // Sanity: a well-formed bearer is extracted.
        #expect(OpenAIAuthGate.bearerToken(fromHeader: "Bearer sk-senkani-abc") == "sk-senkani-abc")
        #expect(OpenAIAuthGate.bearerToken(fromHeader: "bearer sk-senkani-abc") == "sk-senkani-abc")
        #expect(OpenAIAuthGate.bearerToken(fromHeader: "Bearer ") == nil)
    }

    // MARK: - 4. unknown key → 401

    @Test("well-formed key not in the vault → 401")
    func unknownKey401() {
        let known = Self.record(forKey: "sk-senkani-known")
        let decision = OpenAIAuthGate.decide(
            authorizationHeader: bearer("sk-senkani-unknown"),
            requestedSurface: "chat", now: Date(),
            records: [known], rateLimiter: OpenAIRateLimiter()
        )
        guard case .unauthorized(let reason) = decision else { Issue.record("expected 401, got \(decision)"); return }
        #expect(reason == "invalid key")
    }

    // MARK: - 5. constant-time, no oracle

    @Test("constant-time compare folds length deltas (no short-circuit) and is correct")
    func constantTimeCompare() {
        #expect(OpenAIAuthGate.constantTimeEquals("abcd", "abcd") == true)
        #expect(OpenAIAuthGate.constantTimeEquals("abcd", "abce") == false)
        // Length mismatch must not crash and must return false.
        #expect(OpenAIAuthGate.constantTimeEquals("abc", "abcd") == false)
        #expect(OpenAIAuthGate.constantTimeEquals("", "x") == false)
        #expect(OpenAIAuthGate.constantTimeEquals("", "") == true)
    }

    @Test("no oracle: 'no such key' and 'wrong key' return identical 401 reasons")
    func noOracleBetweenUnknownAndWrong() {
        let records = [Self.record(forKey: "sk-senkani-real-1"), Self.record(forKey: "sk-senkani-real-2")]
        let limiter = OpenAIRateLimiter()

        // "wrong key" — plausible format, not provisioned.
        let wrong = OpenAIAuthGate.decide(
            authorizationHeader: bearer("sk-senkani-wrong"),
            requestedSurface: "chat", now: Date(), records: records, rateLimiter: limiter
        )
        // "no such key" — empty vault.
        let none = OpenAIAuthGate.decide(
            authorizationHeader: bearer("sk-senkani-wrong"),
            requestedSurface: "chat", now: Date(), records: [], rateLimiter: limiter
        )
        #expect(wrong == none)   // identical decision + reason — no oracle
        #expect(wrong == .unauthorized(reason: "invalid key"))

        // matchRecord traverses and returns the right record for a real key.
        #expect(OpenAIAuthGate.matchRecord(presentedKey: "sk-senkani-real-2", records: records)?.keyHash
                == OpenAIAuthGate.hash("sk-senkani-real-2"))
        #expect(OpenAIAuthGate.matchRecord(presentedKey: "sk-senkani-nope", records: records) == nil)
    }

    // MARK: - 6. out-of-scope → 403

    @Test("valid key, requested surface out of scope → 403")
    func outOfScope403() {
        let chatOnly = Self.record(forKey: "sk-senkani-chatonly", scope: ["chat"])
        let decision = OpenAIAuthGate.decide(
            authorizationHeader: bearer("sk-senkani-chatonly"),
            requestedSurface: "embeddings", now: Date(),
            records: [chatOnly], rateLimiter: OpenAIRateLimiter()
        )
        guard case .forbidden(let reason) = decision else { Issue.record("expected 403, got \(decision)"); return }
        #expect(reason.contains("embeddings"))
    }

    // MARK: - 7. over-rate → 429 + Retry-After

    @Test("over rate limit → 429 with a Retry-After header")
    func overRate429WithRetryAfter() {
        let key = "sk-senkani-rate"
        let rec = Self.record(forKey: key, rateLimit: 2)
        let limiter = OpenAIRateLimiter()
        let now = Date()
        func decideNow() -> OpenAIAuthGate.Decision {
            OpenAIAuthGate.decide(
                authorizationHeader: bearer(key), requestedSurface: "chat",
                now: now, records: [rec], rateLimiter: limiter
            )
        }
        // limit = 2 → first two ok, third rejected.
        if case .ok = decideNow() {} else { Issue.record("req 1 should be ok") }
        if case .ok = decideNow() {} else { Issue.record("req 2 should be ok") }
        let third = decideNow()
        guard case .rateLimited(let retryAfter) = third else { Issue.record("expected 429, got \(third)"); return }
        #expect(retryAfter >= 1)

        // The rendered 429 carries a Retry-After header.
        let response = try? #require(OpenAIAuthGate.errorResponse(for: third))
        let text = String(decoding: response ?? Data(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 429 Too Many Requests"))
        #expect(text.contains("Retry-After: \(retryAfter)"))
    }

    @Test("rate window resets after it elapses")
    func rateWindowResets() {
        let limiter = OpenAIRateLimiter()
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(limiter.admit(keyHash: "h", limit: 1, now: t0).allowed == true)
        #expect(limiter.admit(keyHash: "h", limit: 1, now: t0).allowed == false)
        // 61s later → fresh window.
        let t1 = t0.addingTimeInterval(61)
        #expect(limiter.admit(keyHash: "h", limit: 1, now: t1).allowed == true)
    }

    // MARK: - 8. expired → 401

    @Test("expired key → 401")
    func expired401() {
        let key = "sk-senkani-expired"
        let past = Date().addingTimeInterval(-3600)
        let rec = Self.record(forKey: key, expiresAt: past)
        let decision = OpenAIAuthGate.decide(
            authorizationHeader: bearer(key), requestedSurface: "chat",
            now: Date(), records: [rec], rateLimiter: OpenAIRateLimiter()
        )
        guard case .unauthorized(let reason) = decision else { Issue.record("expected 401, got \(decision)"); return }
        #expect(reason == "key expired")

        // A not-yet-expired key with the same surface is allowed.
        let future = Date().addingTimeInterval(3600)
        let live = Self.record(forKey: "sk-senkani-live", expiresAt: future)
        let ok = OpenAIAuthGate.decide(
            authorizationHeader: bearer("sk-senkani-live"), requestedSurface: "chat",
            now: Date(), records: [live], rateLimiter: OpenAIRateLimiter()
        )
        guard case .ok = ok else { Issue.record("live key should be ok, got \(ok)"); return }
    }

    // MARK: - 9. default 60 rpm

    @Test("provisioning without --rate defaults to 60 rpm")
    func default60Rpm() {
        let p = OpenAIKeyProvisioner.provision(
            preset: "openai", scope: ["chat"], rateLimit: OpenAIKeyRecord.defaultRateLimit,
            expiresAt: nil, label: nil, now: Date()
        )
        #expect(p.record.rateLimit == 60)
        // A non-positive rate is normalized to the default by the record.
        #expect(OpenAIKeyRecord(keyHash: "h", preset: "p", scope: [], rateLimit: 0, createdAt: Date()).rateLimit == 60)
    }

    // MARK: - 10. vault-record override rpm

    @Test("vault record overrides the rate limit")
    func recordOverrideRpm() {
        let key = "sk-senkani-override"
        let rec = Self.record(forKey: key, rateLimit: 5)
        #expect(rec.rateLimit == 5)
        let limiter = OpenAIRateLimiter()
        let now = Date()
        var allowed = 0
        for _ in 0..<7 {
            let d = OpenAIAuthGate.decide(
                authorizationHeader: bearer(key), requestedSurface: "chat",
                now: now, records: [rec], rateLimiter: limiter
            )
            if case .ok = d { allowed += 1 }
        }
        #expect(allowed == 5)   // exactly the override, not the 60 default
    }

    // MARK: - auth enforced before the 501 stub

    @Test("auth gate runs on /v1/* BEFORE the 501 stub; falls through when ok")
    func authEnforcedBefore501() {
        // No authenticator → v13a-1 behavior (501).
        let noAuth = OpenAIListener.respond(
            requestLine: "POST /v1/chat/completions HTTP/1.1",
            headers: [:], authenticator: nil
        )
        #expect(String(decoding: noAuth, as: UTF8.self).hasPrefix("HTTP/1.1 501"))

        // Authenticator that denies → 401 returned, 501 never reached.
        let denyAll = OpenAIListener.Authenticator { _, _, _ in .unauthorized(reason: "invalid key") }
        let denied = OpenAIListener.respond(
            requestLine: "POST /v1/chat/completions HTTP/1.1",
            headers: [:], authenticator: denyAll
        )
        #expect(String(decoding: denied, as: UTF8.self).hasPrefix("HTTP/1.1 401"))

        // Authenticator that allows → falls through to the 501 stub.
        let allowAll = OpenAIListener.Authenticator { _, _, _ in .ok(label: nil) }
        let allowed = OpenAIListener.respond(
            requestLine: "POST /v1/chat/completions HTTP/1.1",
            headers: [:], authenticator: allowAll
        )
        #expect(String(decoding: allowed, as: UTF8.self).hasPrefix("HTTP/1.1 501"))

        // Non-/v1 path is never auth-gated even with an authenticator set.
        let root = OpenAIListener.respond(
            requestLine: "GET / HTTP/1.1", headers: [:], authenticator: denyAll
        )
        #expect(String(decoding: root, as: UTF8.self).hasPrefix("HTTP/1.1 404"))
    }

    @Test("header parsing is case-insensitive and stops at the blank line")
    func headerParsing() {
        let req = Data("POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nAUTHORIZATION: Bearer sk-senkani-z\r\n\r\nbody-ignored: nope\r\n".utf8)
        let headers = OpenAIListener.parseHeaders(req)
        #expect(headers["authorization"] == "Bearer sk-senkani-z")
        #expect(headers["host"] == "x")
        #expect(headers["body-ignored"] == nil)   // past the blank line
    }

    // MARK: - live round-trip (Network)

    #if canImport(Network)
    @Test("live listener returns 401 for an unauthenticated /v1/* request")
    func live401Unauthenticated() throws {
        let denyAll = OpenAIListener.Authenticator { _, _, headers in
            OpenAIAuthGate.decide(
                authorizationHeader: headers["authorization"],
                requestedSurface: OpenAIAuthGate.surface(forPath: "/v1/chat/completions"),
                now: Date(), records: [], rateLimiter: OpenAIRateLimiter()
            )
        }
        let listener = OpenAIListener(config: .init(bind: "127.0.0.1", port: 0), authenticator: denyAll)
        try listener.start()
        defer { listener.stop() }
        let port = listener.port
        #expect(port > 0)

        let request = Data("GET /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8)
        let fd = try #require(connectToLocalhost(port: port))
        defer { close(fd) }
        #expect(writeAllToFD(fd, request))
        shutdown(fd, Int32(SHUT_WR))
        let response = String(decoding: readAllUntilEOF(fd), as: UTF8.self)
        #expect(response.hasPrefix("HTTP/1.1 401 Unauthorized"))
        #expect(response.contains("invalid_api_key"))
    }
    #endif
}
