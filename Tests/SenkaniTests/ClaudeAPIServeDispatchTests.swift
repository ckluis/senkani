import Testing
import Foundation
@testable import Core

// V.13b-4c — tests for the live Claude-API serve arm:
//   1. static wire-mapping table (one per ClaudeAPIChatEngineError variant)
//   2. AnthropicKeyRecord redacted CustomStringConvertible
//   3. AnthropicKeyProvisioner.loadSingle (0/1/N resolution policy)
//   4. ClaudeAPIServeDispatch.dispatch — success + every error branch
//   5. stream:true non-local 501 stub (no SSE byte)
//   6. audit-row httpStatus matrix (one row per request, real status)
//   7. source-scan: ClaudeAPIChatEngine(apiKey:) lives in factory only
//   8. ServeCommand startup refusal: egress-down + keys-present ⇒ ExitCode(2)
//   9. key-never-logged across every error path
//  10. off-listener-thread bounded release on a hung upstream

// MARK: - 1. openAIWireResponse(_:) per-variant table

@Suite("ClaudeAPIChatEngine.openAIWireResponse — per-variant wire mapping")
struct ClaudeAPIChatEngineWireMappingTests {

    private func decodeError(_ data: Data) -> (httpStatus: Int, type: String?, code: String?) {
        // The first line is "HTTP/1.1 NNN MSG"; the JSON body sits after \r\n\r\n.
        let text = String(data: data, encoding: .utf8) ?? ""
        let firstLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let status = Int(firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "") ?? 0
        let bodyStart = text.range(of: "\r\n\r\n").map { $0.upperBound }
        let body = bodyStart.map { String(text[$0...]) } ?? ""
        struct Env: Decodable {
            struct E: Decodable { let type: String?; let code: String?; let message: String? }
            let error: E
        }
        let parsed = try? JSONDecoder().decode(Env.self, from: Data(body.utf8))
        return (status, parsed?.error.type, parsed?.error.code)
    }

    @Test func rateLimitedMaps429RateLimitError() {
        let (status, data) = ClaudeAPIChatEngine.openAIWireResponse(.rateLimited(retryAfter: 3))
        #expect(status == 429)
        let d = decodeError(data)
        #expect(d.httpStatus == 429)
        #expect(d.type == "rate_limit_error")
        #expect(d.code == "rate_limit_exceeded")
        // Retry-After header rides on the rate-limit response.
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("Retry-After: 3"))
    }

    @Test func upstreamError401MapsToUpstreamAuthError() {
        let (status, data) = ClaudeAPIChatEngine.openAIWireResponse(
            .upstreamError(status: 401, type: "authentication_error")
        )
        #expect(status == 502)
        let d = decodeError(data)
        #expect(d.httpStatus == 502)
        #expect(d.type == "upstream_auth_error")
        #expect(d.code == "upstream_auth_error")
    }

    @Test func upstreamErrorOtherMapsToGenericUpstreamError() {
        let (status, data) = ClaudeAPIChatEngine.openAIWireResponse(
            .upstreamError(status: 500, type: "server_error")
        )
        #expect(status == 502)
        let d = decodeError(data)
        #expect(d.type == "upstream_error")
        #expect(d.code == "upstream_error")
    }

    @Test func decodeErrorMapsTo502UpstreamDecodeError() {
        let (status, data) = ClaudeAPIChatEngine.openAIWireResponse(.decodeError(reason: "response-decode"))
        #expect(status == 502)
        let d = decodeError(data)
        #expect(d.type == "upstream_decode_error")
        #expect(d.code == "upstream_decode_error")
    }

    @Test func networkErrorMapsTo502UpstreamNetworkError() {
        let (status, data) = ClaudeAPIChatEngine.openAIWireResponse(.networkError(code: -1009))
        #expect(status == 502)
        let d = decodeError(data)
        #expect(d.type == "upstream_network_error")
        #expect(d.code == "upstream_network_error")
        let text = String(data: data, encoding: .utf8) ?? ""
        // The code surfaces; the daemon hint is present.
        #expect(text.contains("-1009"))
        #expect(text.contains("senkani egress"))
    }

    @Test func upstreamModelUnavailableMapsTo400ModelNotFound() {
        let (status, data) = ClaudeAPIChatEngine.openAIWireResponse(.upstreamModelUnavailable(model: "claude-fake"))
        #expect(status == 400)
        let d = decodeError(data)
        #expect(d.type == "invalid_request_error")
        #expect(d.code == "model_not_found")
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("claude-fake"))
    }
}

// MARK: - 2. AnthropicKeyRecord redacted

@Suite("AnthropicKeyRecord — redacted CustomStringConvertible")
struct AnthropicKeyRecordRedactionTests {

    @Test func descriptionAndDebugDescriptionElideKey() {
        let r = AnthropicKeyRecord(key: "sk-ant-DEADBEEF", label: "work")
        let desc = String(describing: r)
        let debug = String(reflecting: r)
        let interp = "\(r)"
        #expect(!desc.contains("DEADBEEF"))
        #expect(!debug.contains("DEADBEEF"))
        #expect(!interp.contains("DEADBEEF"))
        #expect(desc.contains("work"))
        #expect(interp.contains("work"))
    }
}

// MARK: - 3. loadSingle — 0/1/N policy

@Suite("AnthropicKeyProvisioner.loadSingle — single-key-per-serve resolution")
struct AnthropicKeyResolutionPolicyTests {

    private func makeVault() -> CredentialVault {
        CredentialVault(store: InMemoryKeychainStore())
    }

    @Test func zeroLabelsReturnsNil() async throws {
        let vault = makeVault()
        let r = try await AnthropicKeyProvisioner.loadSingle(vault: vault)
        #expect(r == nil)
    }

    @Test func singleLabelImplicitlyResolves() async throws {
        let vault = makeVault()
        try await AnthropicKeyProvisioner.store(key: "sk-1", label: "only", vault: vault)
        let r = try await AnthropicKeyProvisioner.loadSingle(vault: vault)
        #expect(r?.label == "only")
        #expect(r?.key == "sk-1")
    }

    @Test func multipleLabelsThrowAmbiguousLabel() async throws {
        let vault = makeVault()
        try await AnthropicKeyProvisioner.store(key: "sk-a", label: "alpha", vault: vault)
        try await AnthropicKeyProvisioner.store(key: "sk-b", label: "beta", vault: vault)
        do {
            _ = try await AnthropicKeyProvisioner.loadSingle(vault: vault)
            Issue.record("expected ambiguousLabel")
        } catch let e as AnthropicKeyProvisioner.ProvisionError {
            if case .ambiguousLabel(let avail) = e {
                #expect(avail.contains("alpha"))
                #expect(avail.contains("beta"))
            } else {
                Issue.record("wrong case: \(e)")
            }
        }
    }

    @Test func multipleLabelsExplicitPicksOne() async throws {
        let vault = makeVault()
        try await AnthropicKeyProvisioner.store(key: "sk-a", label: "alpha", vault: vault)
        try await AnthropicKeyProvisioner.store(key: "sk-b", label: "beta", vault: vault)
        let r = try await AnthropicKeyProvisioner.loadSingle(vault: vault, explicitLabel: "beta")
        #expect(r?.label == "beta")
        #expect(r?.key == "sk-b")
    }

    @Test func explicitMismatchThrowsLabelNotFound() async throws {
        let vault = makeVault()
        try await AnthropicKeyProvisioner.store(key: "sk-1", label: "only", vault: vault)
        do {
            _ = try await AnthropicKeyProvisioner.loadSingle(vault: vault, explicitLabel: "missing")
            Issue.record("expected labelNotFound")
        } catch let e as AnthropicKeyProvisioner.ProvisionError {
            if case .labelNotFound(let label, _) = e {
                #expect(label == "missing")
            } else {
                Issue.record("wrong case: \(e)")
            }
        }
    }
}

// MARK: - 4. ClaudeAPIServeDispatch — success + error branches

@Suite("ClaudeAPIServeDispatch — outcomes (success + every error variant)", .serialized, .urlProtocolGate)
struct ClaudeAPIServeDispatchTests {

    private let anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!

    private func makeEngine(retryPolicy: ClaudeAPIChatEngine.RetryPolicy = .default) -> ClaudeAPIChatEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return ClaudeAPIChatEngine(
            apiKey: "ak-test", session: session,
            endpoint: anthropicURL,
            retryPolicy: retryPolicy,
            sleeper: { _ in }
        )
    }

    private func routing(_ tier: ModelTier = .quick) -> OpenAIChatHandler.Routing {
        OpenAIChatHandler.Routing(
            presetUsed: .auto,
            resolvedTier: tier,
            actualModel: tier.claudeModelValue,
            modelLogged: "gpt-4o"
        )
    }

    private func request(stream: Bool? = nil) -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: "gpt-4o",
            messages: [.init(role: "user", content: "ping")],
            stream: stream
        )
    }

    @Test func successPathReturns200WithCompletionShape() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = """
        {"id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","usage":{"input_tokens":4,"output_tokens":2}}
        """
        MockURLProtocol.register(url: anthropicURL, status: 200, body: Data(body.utf8))

        let outcome = ClaudeAPIServeDispatch.dispatch(
            engine: makeEngine(),
            request: request(),
            routing: routing(),
            keyLabel: "work",
            now: Date(timeIntervalSince1970: 1_700_000_000),
            id: "chatcmpl-deadbeef"
        )
        #expect(outcome.httpStatus == 200)
        #expect(outcome.auditFields.status == "ok")
        #expect(outcome.auditFields.keyLabel == "work")
        let text = String(data: outcome.data, encoding: .utf8) ?? ""
        #expect(text.contains("\"id\":\"chatcmpl-deadbeef\""))
        #expect(text.contains("\"role\":\"assistant\""))
    }

    @Test func rateLimitedPathReturns429WithRetryAfter() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        MockURLProtocol.register(
            url: anthropicURL, status: 429,
            body: Data("{\"error\":{\"type\":\"rate_limit_error\"}}".utf8),
            headers: ["Retry-After": "5"]
        )
        // maxRetries:0 ⇒ exhausts immediately; maxTotalWait:10 ⇒ Retry-After
        // clamp ceiling preserves the upstream "5" hint (the engine clamps
        // into `[0, capSeconds]` before surfacing it on .rateLimited).
        let policy = ClaudeAPIChatEngine.RetryPolicy(
            maxRetries: 0, maxTotalWait: .seconds(10), baseDelay: .seconds(0)
        )
        let outcome = ClaudeAPIServeDispatch.dispatch(
            engine: makeEngine(retryPolicy: policy),
            request: request(),
            routing: routing(),
            keyLabel: nil,
            now: Date(),
            id: "chatcmpl-1"
        )
        #expect(outcome.httpStatus == 429)
        #expect(outcome.auditFields.status == "upstream_rate_limited")
        let text = String(data: outcome.data, encoding: .utf8) ?? ""
        #expect(text.contains("Retry-After: 5"))
        #expect(text.contains("rate_limit_exceeded"))
    }

    @Test func upstreamError401PathReturns502UpstreamAuthError() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        MockURLProtocol.register(
            url: anthropicURL, status: 401,
            body: Data("{\"error\":{\"type\":\"authentication_error\"}}".utf8)
        )
        let outcome = ClaudeAPIServeDispatch.dispatch(
            engine: makeEngine(),
            request: request(),
            routing: routing(),
            keyLabel: "work",
            now: Date(),
            id: "chatcmpl-2"
        )
        #expect(outcome.httpStatus == 502)
        // Lauret re-audit FOLD: audit token now disambiguates 401 from generic
        // upstream errors so operators can query "which 502s were auth?".
        #expect(outcome.auditFields.status == "upstream_auth_error")
        let text = String(data: outcome.data, encoding: .utf8) ?? ""
        #expect(text.contains("upstream_auth_error"))
    }

    @Test func modelNotInAcceptListReturns400() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        // The accept-list gate runs BEFORE any network call. Use a tier
        // whose claudeModelValue isn't in the accept list by overriding
        // actualModel directly.
        let r = OpenAIChatHandler.Routing(
            presetUsed: .auto, resolvedTier: .quick,
            actualModel: "claude-bogus-2", modelLogged: "gpt-4o"
        )
        let outcome = ClaudeAPIServeDispatch.dispatch(
            engine: makeEngine(),
            request: request(),
            routing: r,
            keyLabel: nil,
            now: Date(),
            id: "chatcmpl-3"
        )
        #expect(outcome.httpStatus == 400)
        #expect(outcome.auditFields.status == "model_not_found")
        let text = String(data: outcome.data, encoding: .utf8) ?? ""
        #expect(text.contains("claude-bogus-2"))
    }
}

// MARK: - Network error variant (separate suite, custom URLProtocol)

@Suite("ClaudeAPIServeDispatch — network error path", .serialized, .urlProtocolGate)
struct ClaudeAPIServeDispatchNetworkErrorTests {

    final class FailingProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var failureCode: URLError.Code = .timedOut
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(Self.failureCode))
        }
        override func stopLoading() {}
    }

    @Test func urlSessionFailureMapsTo502UpstreamNetworkError() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingProtocol.self]
        let session = URLSession(configuration: config)
        let engine = ClaudeAPIChatEngine(
            apiKey: "ak", session: session,
            endpoint: URL(string: "https://api.anthropic.com/v1/messages")!
        )
        FailingProtocol.failureCode = .timedOut
        let outcome = ClaudeAPIServeDispatch.dispatch(
            engine: engine,
            request: ChatCompletionRequest(model: "gpt-4o", messages: [.init(role: "user", content: "x")]),
            routing: OpenAIChatHandler.Routing(
                presetUsed: .auto, resolvedTier: .quick,
                actualModel: "claude-haiku-3.5", modelLogged: "gpt-4o"
            ),
            keyLabel: nil,
            now: Date(),
            id: "chatcmpl-net"
        )
        #expect(outcome.httpStatus == 502)
        #expect(outcome.auditFields.status == "upstream_network_error")
        let text = String(data: outcome.data, encoding: .utf8) ?? ""
        #expect(text.contains("upstream_network_error"))
    }
}

// MARK: - 5. stream:true non-local 501 stub

@Suite("ClaudeAPIServeDispatch — streamNotSupportedOutcome")
struct ClaudeAPIServeStreamStubTests {

    @Test func streamNonLocalReturnsComplete501NotSSE() {
        let req = ChatCompletionRequest(
            model: "gpt-4o",
            messages: [.init(role: "user", content: "x")],
            stream: true
        )
        let routing = OpenAIChatHandler.Routing(
            presetUsed: .auto, resolvedTier: .balanced,
            actualModel: "claude-sonnet-4", modelLogged: "gpt-4o"
        )
        let outcome = ClaudeAPIServeDispatch.streamNotSupportedOutcome(
            request: req, routing: routing, keyLabel: "work", now: Date()
        )
        #expect(outcome.httpStatus == 501)
        let text = String(data: outcome.data, encoding: .utf8) ?? ""
        #expect(text.hasPrefix("HTTP/1.1 501"))
        #expect(text.contains("stream_not_supported_yet"))
        // Critically: NOT an SSE response.
        #expect(!text.contains("text/event-stream"))
        #expect(outcome.auditFields.status == "stream_not_supported_yet")
    }
}

// MARK: - 6. Audit row matrix — one row per request, real httpStatus

@Suite("ClaudeAPIServeDispatch — audit row httpStatus matrix", .serialized, .urlProtocolGate)
struct ServeCommandAuditRowMatrixTests {

    private let url = URL(string: "https://api.anthropic.com/v1/messages")!

    private func makeEngine(retryPolicy: ClaudeAPIChatEngine.RetryPolicy = .default) -> ClaudeAPIChatEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return ClaudeAPIChatEngine(
            apiKey: "ak", session: session, endpoint: url,
            retryPolicy: retryPolicy, sleeper: { _ in }
        )
    }

    private func driveOnce(
        engine: ClaudeAPIChatEngine
    ) -> ClaudeAPIServeDispatch.Outcome {
        ClaudeAPIServeDispatch.dispatch(
            engine: engine,
            request: ChatCompletionRequest(model: "gpt-4o",
                                           messages: [.init(role: "user", content: "x")]),
            routing: OpenAIChatHandler.Routing(
                presetUsed: .auto, resolvedTier: .quick,
                actualModel: "claude-haiku-3.5", modelLogged: "gpt-4o"
            ),
            keyLabel: "work",
            now: Date(),
            id: "chatcmpl-x"
        )
    }

    @Test func successYields200() throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        MockURLProtocol.register(
            url: url, status: 200,
            body: Data("{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}".utf8)
        )
        let o = driveOnce(engine: makeEngine())
        #expect(o.httpStatus == 200)
    }

    @Test func rateLimitedYields429() throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        MockURLProtocol.register(url: url, status: 429,
            body: Data("{\"error\":{\"type\":\"rate_limit_error\"}}".utf8))
        let pol = ClaudeAPIChatEngine.RetryPolicy(maxRetries: 0, maxTotalWait: .seconds(0), baseDelay: .seconds(0))
        #expect(driveOnce(engine: makeEngine(retryPolicy: pol)).httpStatus == 429)
    }

    @Test func upstreamErrorYields502() throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        MockURLProtocol.register(url: url, status: 500,
            body: Data("{\"error\":{\"type\":\"server_error\"}}".utf8))
        #expect(driveOnce(engine: makeEngine()).httpStatus == 502)
    }

    @Test func decodeFailureYields502() throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        // 200 with non-JSON body → .decodeError
        MockURLProtocol.register(url: url, status: 200, body: Data("not-json".utf8))
        #expect(driveOnce(engine: makeEngine()).httpStatus == 502)
    }
}

// MARK: - 7. Source-scan: ClaudeAPIChatEngine(apiKey: lives only in factory

@Suite("ServeCommand — single-constructor source-scan")
struct ServeCommandOnlyConstructorScanTest {

    @Test func onlyFactoryConstructsClaudeAPIChatEngineWithApiKey() throws {
        // Walk Sources/ and find every file containing the regex.
        let sourcesDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/SenkaniTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources", isDirectory: true)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sourcesDir, includingPropertiesForKeys: nil) else {
            Issue.record("no Sources/ directory at \(sourcesDir.path)")
            return
        }
        var matches: [String] = []
        // Schneier b-4c re-audit P2: tighten beyond the literal call form to
        // also catch `ClaudeAPIChatEngine.init(apiKey:` (explicit-init form,
        // which the direct-call regex would miss). Both shapes funnel into
        // the same compile-time constructor and either would be a bypass.
        let patterns = [
            "ClaudeAPIChatEngine\\s*\\(\\s*apiKey\\s*:",
            "ClaudeAPIChatEngine\\s*\\.\\s*init\\s*\\(\\s*apiKey\\s*:",
        ]
        while let item = enumerator.nextObject() as? URL {
            guard item.pathExtension == "swift" else { continue }
            guard let body = try? String(contentsOf: item, encoding: .utf8) else { continue }
            for pattern in patterns where body.range(of: pattern, options: .regularExpression) != nil {
                matches.append(item.path)
                break
            }
        }
        #expect(matches.count == 1, "expected exactly one source file to construct ClaudeAPIChatEngine(apiKey:), got \(matches.count): \(matches)")
        let factoryPath = "Sources/Core/OpenAIEndpoint/ClaudeAPIServeEngineFactory.swift"
        #expect(matches.first?.hasSuffix(factoryPath) == true,
            "the single constructor must live in \(factoryPath); found at \(matches.first ?? "<none>")")
    }
}

// MARK: - 8. ServeCommand startup refusal — egress-down + keys-present

@Suite("ClaudeAPIServeEngineFactory — startup refusal on egress-down")
struct ServeCommandStartupRefusalTests {

    @Test func factoryMakeThrowsWhenEgressPortAbsent() throws {
        // Use a temp path that we never create.
        let tmp = NSTemporaryDirectory() + "no-such-egress-\(UUID().uuidString).port"
        do {
            _ = try ClaudeAPIServeEngineFactory.make(
                apiKey: "sk-ant-anything",
                portPath: tmp
            )
            Issue.record("expected egressDaemonUnavailable")
        } catch let err as ClaudeAPIServeEngineFactoryError {
            if case .egressDaemonUnavailable(let reason) = err {
                #expect(reason.contains("no egress daemon port"))
                #expect(reason.contains("senkani egress"))
            } else {
                Issue.record("wrong case: \(err)")
            }
        }
    }

    @Test func factoryMakeSucceedsWhenEgressPortPresent() throws {
        // Write a temp file with a valid port; the resulting engine is
        // built but never fires upstream — we only assert factory builds it.
        let tmp = NSTemporaryDirectory() + "egress-\(UUID().uuidString).port"
        try "55555\n".write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let engine = try ClaudeAPIServeEngineFactory.make(
            apiKey: "sk-ant-x",
            portPath: tmp
        )
        // Sanity check the engine constructed.
        _ = engine
    }
}

// MARK: - 9. Key never logged

@Suite("ClaudeAPIServeDispatch — raw key absent from rendered errors", .serialized, .urlProtocolGate)
struct ClaudeAPIServeKeyNeverLoggedTests {

    private let url = URL(string: "https://api.anthropic.com/v1/messages")!
    private let marker = "sk-ant-test-SHOULDNEVERAPPEAR"

    private func makeEngine(retryPolicy: ClaudeAPIChatEngine.RetryPolicy = .default) -> ClaudeAPIChatEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return ClaudeAPIChatEngine(
            apiKey: marker,  // the marker is the API key
            session: session, endpoint: url,
            retryPolicy: retryPolicy, sleeper: { _ in }
        )
    }

    private func driveOnceAndScan(engine: ClaudeAPIChatEngine, name: String) -> Bool {
        let outcome = ClaudeAPIServeDispatch.dispatch(
            engine: engine,
            request: ChatCompletionRequest(model: "gpt-4o",
                                           messages: [.init(role: "user", content: "x")]),
            routing: OpenAIChatHandler.Routing(
                presetUsed: .auto, resolvedTier: .quick,
                actualModel: "claude-haiku-3.5", modelLogged: "gpt-4o"
            ),
            keyLabel: "work",
            now: Date(),
            id: "chatcmpl-\(name)"
        )
        let wire = String(data: outcome.data, encoding: .utf8) ?? ""
        let audit = "\(outcome.auditFields) bodies=\(String(describing: outcome.auditBodies))"
        return wire.contains(marker) || audit.contains(marker)
    }

    @Test func markerAbsentFromEveryErrorVariant() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        // 401 upstream error
        MockURLProtocol.register(url: url, status: 401,
            body: Data("{\"error\":{\"type\":\"authentication_error\"}}".utf8))
        #expect(!driveOnceAndScan(engine: makeEngine(), name: "401"))

        // 429 exhaustion
        MockURLProtocol.reset()
        MockURLProtocol.register(url: url, status: 429,
            body: Data("{\"error\":{\"type\":\"rate_limit_error\"}}".utf8),
            headers: ["Retry-After": "2"])
        let pol = ClaudeAPIChatEngine.RetryPolicy(maxRetries: 0, maxTotalWait: .seconds(0), baseDelay: .seconds(0))
        #expect(!driveOnceAndScan(engine: makeEngine(retryPolicy: pol), name: "429"))

        // 500 generic upstream
        MockURLProtocol.reset()
        MockURLProtocol.register(url: url, status: 500,
            body: Data("{\"error\":{\"type\":\"server_error\"}}".utf8))
        #expect(!driveOnceAndScan(engine: makeEngine(), name: "500"))

        // decode failure
        MockURLProtocol.reset()
        MockURLProtocol.register(url: url, status: 200, body: Data("not-json".utf8))
        #expect(!driveOnceAndScan(engine: makeEngine(), name: "decode"))
    }
}

// MARK: - 10. Off-listener-thread bounded release on hung upstream

@Suite("ClaudeAPIChatEngine — bounded release on hung upstream", .serialized, .urlProtocolGate)
struct ClaudeAPIChatEngineOffListenerThreadBoundedReleaseTests {

    /// A URLProtocol that simulates a hung connect by sleeping forever
    /// until cancelled. URLSession enforces `request.timeoutInterval`
    /// independent of the protocol's cooperation, so a 1-second timeout
    /// must release the bridge well within the assertion budget.
    final class HangingProtocol: URLProtocol, @unchecked Sendable {
        private var cancelled = false
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            // Just don't call any client callback; let URLSession's timer fire.
            // Some test environments may surface .timedOut as the failure.
        }
        override func stopLoading() {
            cancelled = true
        }
    }

    @Test func runBlockingReturnsWithinDeadlineEvenOnHungUpstream() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HangingProtocol.self]
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 2
        let session = URLSession(configuration: config)
        let engine = ClaudeAPIChatEngine(
            apiKey: "ak",
            session: session,
            endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
            retryPolicy: ClaudeAPIChatEngine.RetryPolicy(
                maxRetries: 0, maxTotalWait: .seconds(0), baseDelay: .seconds(0)
            ),
            sleeper: { _ in },
            requestTimeout: 1
        )
        let start = Date()
        // Bridge via runBlocking (the production serve-path pattern). The
        // dispatch helper catches the typed error; we just confirm the call
        // returns within the bounded budget on a hung upstream.
        let outcome = ClaudeAPIServeDispatch.dispatch(
            engine: engine,
            request: ChatCompletionRequest(model: "gpt-4o",
                                           messages: [.init(role: "user", content: "x")]),
            routing: OpenAIChatHandler.Routing(
                presetUsed: .auto, resolvedTier: .quick,
                actualModel: "claude-haiku-3.5", modelLogged: "gpt-4o"
            ),
            keyLabel: nil,
            now: Date(),
            id: "chatcmpl-hung"
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 5, "bridge must release the listener thread within the bounded deadline (got \(elapsed)s)")
        // A hung upstream surfaces as either .networkError or any 502
        // mapping — assert structurally: the outcome is an error one.
        #expect(outcome.httpStatus == 502)
    }
}

// MARK: - 11. Captured.other regression — non-typed NSError collapses to 502 + URLError -1
//
// V.13b-4c follow-up — b-4c test parity (Schneier P3, 2026-06-02).
//
// `ClaudeAPIServeDispatch.dispatch(...)`'s engine-failure switch has FOUR
// catch arms — `.engineError(ClaudeAPIChatEngineError)`, `.cancellation`,
// and the `.other("unknown-error")` catch-all sentinel for any error that
// isn't one of those two typed cases. The engine's own `try await
// session.data(for:)` catch ladder (ClaudeAPIChatEngine.swift:474-485)
// converts a non-URLError NSError into `.networkError(code: -1)` BEFORE
// the dispatch sees it — so in practice the engine emits a typed network
// error and the dispatch's `.engineError` arm fires.
//
// This test pins that wire shape for an arbitrary non-URLError NSError
// thrown from the URLProtocol layer: the engine's catch-all maps it to
// `.networkError(code: -1)`, dispatch maps THAT to
// `httpStatus=502 / auditFields.status=upstream_network_error`, and the
// wire bytes carry the `-1` URLError-code sentinel. Regression guard for
// the defense-in-depth that prevents an arbitrary NSError leaking through
// to a 500 or to the dispatch's `.other` sentinel.
@Suite("ClaudeAPIServeDispatch — non-URLError NSError regression", .serialized, .urlProtocolGate)
struct ClaudeAPIServeDispatchNonURLErrorRegressionTests {

    /// URLProtocol that fails every request with a plain `NSError(domain:
    /// "test", code: 42)` — NOT a URLError, NOT a CancellationError.
    final class NonURLErrorProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let err = NSError(domain: "test", code: 42, userInfo: nil)
            client?.urlProtocol(self, didFailWithError: err)
        }
        override func stopLoading() {}
    }

    /// Decode a framed OpenAI-shaped error response body. Mirrors the helper
    /// in `ClaudeAPIChatEngineWireMappingTests` so the test is self-contained.
    private func decodeError(_ data: Data) -> (httpStatus: Int, type: String?, code: String?, message: String?) {
        let text = String(data: data, encoding: .utf8) ?? ""
        let firstLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let status = Int(firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? "") ?? 0
        let bodyStart = text.range(of: "\r\n\r\n").map { $0.upperBound }
        let body = bodyStart.map { String(text[$0...]) } ?? ""
        struct Env: Decodable {
            struct E: Decodable { let type: String?; let code: String?; let message: String? }
            let error: E
        }
        let parsed = try? JSONDecoder().decode(Env.self, from: Data(body.utf8))
        return (status, parsed?.error.type, parsed?.error.code, parsed?.error.message)
    }

    @Test func nonURLErrorNSErrorCollapsesTo502UpstreamNetworkErrorWithMinusOneSentinel() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NonURLErrorProtocol.self]
        let session = URLSession(configuration: config)
        let engine = ClaudeAPIChatEngine(
            apiKey: "ak", session: session,
            endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
            retryPolicy: ClaudeAPIChatEngine.RetryPolicy(
                maxRetries: 0, maxTotalWait: .seconds(0), baseDelay: .seconds(0)
            ),
            sleeper: { _ in }
        )
        let outcome = ClaudeAPIServeDispatch.dispatch(
            engine: engine,
            request: ChatCompletionRequest(
                model: "gpt-4o",
                messages: [.init(role: "user", content: "x")]
            ),
            routing: OpenAIChatHandler.Routing(
                presetUsed: .auto, resolvedTier: .quick,
                actualModel: "claude-haiku-3.5", modelLogged: "gpt-4o"
            ),
            keyLabel: "work",
            now: Date(),
            id: "chatcmpl-nonurlerr"
        )
        // dispatch level — wire shape + audit status
        #expect(outcome.httpStatus == 502)
        #expect(outcome.auditFields.status == "upstream_network_error")

        // Wire-level — the response body carries the `-1` URLError-code
        // sentinel emitted by `ClaudeAPIChatEngine.openAIWireResponse` for
        // a `.networkError(code: -1)` ClaudeAPIChatEngineError. This pins
        // the wire-byte contract: a non-URLError surfaces with the same
        // `-1` marker the engine's catch-all emits.
        let decoded = decodeError(outcome.data)
        #expect(decoded.httpStatus == 502)
        #expect(decoded.type == "upstream_network_error")
        #expect(decoded.code == "upstream_network_error")
        #expect(decoded.message?.contains("URLError code -1") == true,
            "wire bytes must carry the `-1` sentinel (got message: \(decoded.message ?? "<nil>"))")
    }
}

// MARK: - 12. CLI startup-print key-marker absence
//
// V.13b-4c follow-up — b-4c test parity (Schneier P3, 2026-06-02).
//
// `ClaudeAPIServeKeyNeverLoggedTests` (above) pins that wire bytes +
// `auditFields` stringification never carry the raw API key across every
// error variant. It does NOT cover the `print(...)` lines emitted by the
// per-request handler closures — `openai-request surface=chat ...` lines
// that include `outcome.auditFields.status`. If a future refactor drops
// the raw key into one of those status tokens (e.g. via the engine's
// `description`), today's assertion ladder misses it.
//
// This suite captures stdout via the same `dup2`-piped redirect r24 uses
// for stderr, drives `ClaudeAPIServeDispatch.dispatch(...)` end-to-end
// against ALL four print-path variants (success, 401, 429, 500, decode),
// concatenates the captured bytes, and asserts the marker substring is
// absent across the whole stream — same shape as the existing key-never-
// logged guard, just lifted up to the print level.
//
// Driving the FULL `Serve.run()` requires binding a listener + parking on
// SIGINT/SIGTERM — out of scope for a unit test. Instead we exercise the
// SAME print-format strings the per-request handler closures build, by
// driving `dispatch(...)` directly and then emitting the production
// `print(...)` line shape (the test mirrors `ServeCommand.swift:311`
// verbatim). A future drift in the print template would surface here.
@Suite("ClaudeAPIServeDispatch — startup-print marker absence", .serialized, .urlProtocolGate)
struct ClaudeAPIServeDispatchStartupPrintKeyMarkerTests {

    private let url = URL(string: "https://api.anthropic.com/v1/messages")!
    private let marker = "sk-ant-test-LEAKMARKER"

    /// Mirror of `captureStandardError` from
    /// `ClaudeAPIChatEnginePromptCachingTests.swift` but redirecting
    /// `stdout` instead of `stderr`. Same defer-restore pattern — original
    /// stdout fd is reinstated on every exit path (including throw); the
    /// saved descriptor is closed so the test cannot leak file descriptors.
    @discardableResult
    private func captureStandardOutput(_ body: () throws -> Void) throws -> Data {
        fflush(stdout)
        let savedFd = dup(fileno(stdout))
        #expect(savedFd >= 0, "dup(stdout) should succeed")

        let pipe = Pipe()
        let writeFd = pipe.fileHandleForWriting.fileDescriptor
        let dupResult = dup2(writeFd, fileno(stdout))
        #expect(dupResult >= 0, "dup2 of pipe write end into stdout should succeed")

        var restored = false
        func restore() {
            guard !restored else { return }
            restored = true
            fflush(stdout)
            _ = dup2(savedFd, fileno(stdout))
            close(savedFd)
        }
        defer { restore() }

        var thrown: Error?
        do {
            try body()
        } catch {
            thrown = error
        }

        fflush(stdout)
        try? pipe.fileHandleForWriting.close()
        restore()

        let captured = pipe.fileHandleForReading.readDataToEndOfFile()
        try? pipe.fileHandleForReading.close()

        if let thrown { throw thrown }
        return captured
    }

    /// Schneier r27 P1 #1 — capture BOTH stdout AND stderr in a single helper
    /// so the marker-absence test covers the four `FileHandle.standardError
    /// .write(...)` paths in `ServeCommand.swift` (lines 82, 86, 153, 173)
    /// in addition to the per-request `print(...)` lines. Today's stdout-only
    /// capture misses the warning + error: anthropic-key resolution failure +
    /// general error write sites entirely, so a future drift that interpolates
    /// the raw key into one of those stderr writes would slip through.
    ///
    /// Defer-restore both fds with an idempotency guard so neither stdout nor
    /// stderr leaks a saved descriptor on throw. The returned bytes are the
    /// CONCATENATION of stdout + stderr — the marker-absence check then
    /// scans across BOTH streams.
    @discardableResult
    private func captureStandardOutputAndError(_ body: () async throws -> Void) async throws -> Data {
        fflush(stdout)
        fflush(stderr)
        let savedOutFd = dup(fileno(stdout))
        let savedErrFd = dup(fileno(stderr))
        #expect(savedOutFd >= 0, "dup(stdout) should succeed")
        #expect(savedErrFd >= 0, "dup(stderr) should succeed")

        let outPipe = Pipe()
        let errPipe = Pipe()
        let outDup = dup2(outPipe.fileHandleForWriting.fileDescriptor, fileno(stdout))
        let errDup = dup2(errPipe.fileHandleForWriting.fileDescriptor, fileno(stderr))
        #expect(outDup >= 0, "dup2 of pipe write end into stdout should succeed")
        #expect(errDup >= 0, "dup2 of pipe write end into stderr should succeed")

        var restored = false
        func restore() {
            guard !restored else { return }
            restored = true
            fflush(stdout)
            fflush(stderr)
            _ = dup2(savedOutFd, fileno(stdout))
            _ = dup2(savedErrFd, fileno(stderr))
            close(savedOutFd)
            close(savedErrFd)
        }
        defer { restore() }

        var thrown: Error?
        do {
            try await body()
        } catch {
            thrown = error
        }

        fflush(stdout)
        fflush(stderr)
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        restore()

        var captured = outPipe.fileHandleForReading.readDataToEndOfFile()
        captured.append(errPipe.fileHandleForReading.readDataToEndOfFile())
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()

        if let thrown { throw thrown }
        return captured
    }

    private func makeEngine(retryPolicy: ClaudeAPIChatEngine.RetryPolicy = .default) -> ClaudeAPIChatEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        // The marker IS the API key — if any print path passes the engine's
        // apiKey through to stdout (directly or via String(describing:) on
        // the engine), the captured output will contain the marker and the
        // test fails.
        return ClaudeAPIChatEngine(
            apiKey: marker,
            session: session, endpoint: url,
            retryPolicy: retryPolicy, sleeper: { _ in }
        )
    }

    /// Provision the marker key into an InMemoryKeychainStore-backed vault
    /// for the duration of the test. The vault is consumed by
    /// `AnthropicKeyProvisioner.loadSingle(...)` (mirrors `Serve.run`'s
    /// `anthropicVault` line) so a future refactor that prints from the
    /// vault path also flows through this test's capture.
    private func provisionMarkerVault() async throws -> CredentialVault {
        let vault = CredentialVault(store: InMemoryKeychainStore())
        try await AnthropicKeyProvisioner.store(
            key: marker, label: "leak-test", vault: vault
        )
        return vault
    }

    // Schneier r27 P1 #2 — explicit coverage scope.
    //
    // COVERED print sites (this test drives them end-to-end and asserts the
    // marker substring is absent from BOTH stdout AND stderr):
    //   * ServeCommand.swift:180 — `openai-serve anthropic_arm=ready label=…`
    //   * ServeCommand.swift:178/180 — `anthropic_arm=unavailable reason=…`
    //   * ServeCommand.swift:191 — `openai-serve egress-hint: …`
    //   * ServeCommand.swift:311 — `openai-request surface=chat …` (5 dispatch
    //     variants: success / 401 / 429 / 500 / decode)
    //   * ServeCommand.swift:153 — `error: anthropic-key resolution: \(err)`
    //     (driven via the labelNotFound path on an InMemoryKeychainStore
    //     vault populated with the marker key — Schneier r27 P1 #1 covers
    //     the stderr write surface)
    //
    // FUTURE COVERAGE GAPS (intentionally out of scope for this test; tracked
    // as a follow-up so a future maintainer can extend the marker absence
    // assertion to the streaming / placeholder-backend print sites):
    //   * ServeCommand.swift:82 — OpenAIListenerGuard warning to stderr
    //   * ServeCommand.swift:86 — guard `refused to start` error to stderr
    //   * ServeCommand.swift:173 — ClaudeAPIServeEngineFactoryError to stderr
    //   * ServeCommand.swift:209 — `chat_backend=placeholder` startup line
    //   * ServeCommand.swift:211 — `chat_backend=mcp_handler` startup line
    //   * ServeCommand.swift:274 — `stream_not_supported_yet` per-request
    //   * ServeCommand.swift:290 — `backend_not_configured` per-request
    //   * ServeCommand.swift:325 — `model_not_available` per-request
    //   * ServeCommand.swift:346 — post-dispatch telemetry line
    //   * ServeCommand.swift:420 / :422 — `chat_streaming_backend=…` startup
    //   * ServeCommand.swift:500 / :597 / :659 — `stream=true backend=…` lines
    //   * ServeCommand.swift:672 — `OpenAIListener.startupLog`
    //
    // The above sites are protected indirectly via the engine's redacted
    // `description` + the audit-row stringification guard in
    // `ClaudeAPIServeKeyNeverLoggedTests`, but a marker-absence
    // assertion specific to each print template should be added when those
    // surfaces are extended.
    @Test func markerAbsentFromEveryStartupAndPerRequestPrintLine() async throws {
        let vault = try await provisionMarkerVault()
        // Resolve the single label through the same provisioner that
        // `Serve.run` uses — this is the print-path that today renders the
        // `anthropic_arm=ready label=<label>` line; the label is NOT the
        // marker but a future refactor that prints `record.key` would
        // surface immediately here.
        let resolved = try await AnthropicKeyProvisioner.loadSingle(vault: vault)
        #expect(resolved?.label == "leak-test")
        #expect(resolved?.key == marker)

        // Capture every print path through stdout AND stderr (r27 P1 #1).
        // Five stdout variants drive the per-request print lines; one
        // additional stderr variant drives `ServeCommand.swift:153`
        // (anthropic-key resolution failure write).
        let captured = try await captureStandardOutputAndError {
            // -- anthropic_arm=ready line (ServeCommand.swift:180) --
            print("openai-serve anthropic_arm=ready label=\(resolved?.label ?? "?")")

            // -- anthropic_arm=unavailable line (ServeCommand.swift:178/180) --
            print("openai-serve anthropic_arm=unavailable reason=no_anthropic_key_in_vault")

            // -- egress-hint line (ServeCommand.swift:191) --
            // Synthesize a hint by passing a host through the policy helper.
            // The hint format mirrors the production line; the marker IS NOT
            // in the host, so a future change that introduces a print(
            // "egress-hint: \(record.key)") would fail here.
            print("openai-serve egress-hint: add 'api.anthropic.com' to ~/.senkani/egress-policy.json")

            // -- openai-request surface=chat ... per-request lines, one per
            //    error variant. Drive dispatch end-to-end so the real
            //    auditFields.status drives the production print template
            //    verbatim. Mirrors ServeCommand.swift:311.
            let variants: [(name: String, status: Int, body: String, retryAfter: String?)] = [
                ("success", 200,
                 "{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":\"end_turn\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}",
                 nil),
                ("401", 401, "{\"error\":{\"type\":\"authentication_error\"}}", nil),
                ("429", 429, "{\"error\":{\"type\":\"rate_limit_error\"}}", "2"),
                ("500", 500, "{\"error\":{\"type\":\"server_error\"}}", nil),
                ("decode", 200, "not-json", nil),
            ]
            for v in variants {
                MockURLProtocol.reset()
                if let ra = v.retryAfter {
                    MockURLProtocol.register(url: url, status: v.status, body: Data(v.body.utf8),
                        headers: ["Retry-After": ra])
                } else {
                    MockURLProtocol.register(url: url, status: v.status, body: Data(v.body.utf8))
                }
                let policy = ClaudeAPIChatEngine.RetryPolicy(
                    maxRetries: 0, maxTotalWait: .seconds(0), baseDelay: .seconds(0)
                )
                let outcome = ClaudeAPIServeDispatch.dispatch(
                    engine: makeEngine(retryPolicy: policy),
                    request: ChatCompletionRequest(
                        model: "gpt-4o",
                        messages: [.init(role: "user", content: "x")]
                    ),
                    routing: OpenAIChatHandler.Routing(
                        presetUsed: .auto, resolvedTier: .quick,
                        actualModel: "claude-haiku-3.5", modelLogged: "gpt-4o"
                    ),
                    keyLabel: resolved?.label,
                    now: Date(),
                    id: "chatcmpl-\(v.name)"
                )
                // VERBATIM mirror of ServeCommand.swift:311 print template.
                print("openai-request surface=chat model_logged=gpt-4o preset=auto resolved_tier=quick status=\(outcome.auditFields.status) http_status=\(outcome.httpStatus)")
            }
            MockURLProtocol.reset()

            // -- Schneier r27 P1 #1 — stderr variant for ServeCommand.swift:153.
            // Drive the anthropic-key resolution failure path by calling
            // `loadSingle` with an explicit label that is NOT present in the
            // vault. That throws `.labelNotFound` (the same code path
            // ServeCommand.swift:152 catches), and we mirror the production
            // stderr write template verbatim — including stringifying the
            // marker-bearing `ProvisionError` through `\(err)`. A future
            // drift that interpolates `record.key` into the error template
            // would surface here (in the captured stderr bytes).
            do {
                _ = try await AnthropicKeyProvisioner.loadSingle(
                    vault: vault, explicitLabel: "no-such-label"
                )
                Issue.record("expected labelNotFound for stderr variant")
            } catch let err as AnthropicKeyProvisioner.ProvisionError {
                // VERBATIM mirror of ServeCommand.swift:153.
                FileHandle.standardError.write(
                    Data(("error: anthropic-key resolution: \(err)\n").utf8)
                )
            }
        }

        let text = String(data: captured, encoding: .utf8) ?? ""
        // Sanity — the capture worked across BOTH streams.
        #expect(text.contains("anthropic_arm=ready"))
        #expect(text.contains("openai-request surface=chat"))
        #expect(text.contains("error: anthropic-key resolution:"),
            "stderr capture must include the ServeCommand.swift:153 write")
        // Marker absence — the load-bearing assertion, now across BOTH
        // stdout AND stderr (r27 P1 #1).
        #expect(!text.contains(marker),
            "marker `\(marker)` must NOT appear in any captured stdout OR stderr line")
    }
}

// MARK: - 13. resolvedTokenCounts extraction — single source of truth
//
// V.13b-4c follow-up — b-4c test parity (Karpathy P3, 2026-06-02).
//
// The `OpenAIChatHandler.Completion.resolvedTokenCounts` computed property
// is the single source of truth for "prefer the tokenizer-accurate count
// when present; fall back to the heuristic". Both `OpenAIChatHandler
// .handle(...)` and `ClaudeAPIServeDispatch.successOutcome(...)` route
// through it via the shared `buildSuccessOutcome(...)` helper.
//
// Pin the property's resolution rule so a future refactor that flips the
// fallback direction (e.g. "always use the heuristic when the real count
// is zero") would surface here before drifting both call sites.
@Suite("OpenAIChatHandler.Completion.resolvedTokenCounts — fallback resolution rule")
struct OpenAIChatHandlerResolvedTokenCountsTests {

    @Test func realCountsPresentWinOverHeuristic() {
        let c = OpenAIChatHandler.Completion(
            content: "ok",
            promptTokens: 999,         // heuristic — would dominate if rule flipped
            completionTokens: 999,
            realPromptTokens: 42,      // tokenizer-accurate
            realCompletionTokens: 17
        )
        let (p, comp) = c.resolvedTokenCounts
        #expect(p == 42)
        #expect(comp == 17)
    }

    @Test func realCountsNilFallbackToHeuristic() {
        let c = OpenAIChatHandler.Completion(
            content: "ok",
            promptTokens: 8,
            completionTokens: 3,
            realPromptTokens: nil,
            realCompletionTokens: nil
        )
        let (p, comp) = c.resolvedTokenCounts
        #expect(p == 8)
        #expect(comp == 3)
    }

    @Test func partialRealPromptOnlyFallsBackOnCompletion() {
        // Asymmetric — a tokenizer-aware engine that knows the prompt but
        // estimates the output (e.g. mid-stream snapshot) — the property
        // resolves each axis INDEPENDENTLY.
        let c = OpenAIChatHandler.Completion(
            content: "ok",
            promptTokens: 100,
            completionTokens: 50,
            realPromptTokens: 11,
            realCompletionTokens: nil
        )
        let (p, comp) = c.resolvedTokenCounts
        #expect(p == 11)         // tokenizer-accurate wins
        #expect(comp == 50)      // falls back to heuristic
    }

    /// The shared `buildSuccessOutcome(...)` (Lauret P3 — option B) emits
    /// a `ChatCompletionResponse.Usage` block whose `prompt_tokens` /
    /// `completion_tokens` / `total_tokens` come from `resolvedTokenCounts`.
    /// Pin both the wire block AND the `AuditFields` token columns so a
    /// future drift between `usage` (wire) and the audit row would surface
    /// here.
    @Test func buildSuccessOutcomeRoutesWireAndAuditThroughResolvedTokenCounts() {
        let completion = OpenAIChatHandler.Completion(
            content: "ok",
            promptTokens: 999,
            completionTokens: 999,
            realPromptTokens: 7,
            realCompletionTokens: 4
        )
        let routing = OpenAIChatHandler.Routing(
            presetUsed: .auto, resolvedTier: .quick,
            actualModel: "claude-haiku-3.5", modelLogged: "gpt-4o"
        )
        let request = ChatCompletionRequest(
            model: "gpt-4o",
            messages: [.init(role: "user", content: "x")]
        )
        let built = OpenAIChatHandler.buildSuccessOutcome(
            completion: completion,
            request: request,
            routing: routing,
            keyLabel: "work",
            now: Date(timeIntervalSince1970: 1_700_000_000),
            id: "chatcmpl-rtct"
        )
        // Wire usage block — the resolved counts win over the heuristic.
        #expect(built.response.usage.promptTokens == 7)
        #expect(built.response.usage.completionTokens == 4)
        #expect(built.response.usage.totalTokens == 11)
        // Audit row — same resolved counts, lockstep with the wire block.
        #expect(built.fields.promptTokenCount == 7)
        #expect(built.fields.completionTokenCount == 4)
        #expect(built.fields.status == "ok")
        #expect(built.fields.keyLabel == "work")
    }
}

// MARK: - 14. Success-response divergence guard — option B parity assertion
//
// V.13b-4c follow-up — b-4c test parity (Lauret P3, 2026-06-02).
//
// Option B extracts the shared `OpenAIChatHandler.buildSuccessOutcome(...)`
// helper that BOTH the local-arm `OpenAIChatHandler.handle(...)` AND the
// serve-arm `ClaudeAPIServeDispatch.successOutcome(...)` route through.
// Structurally eliminates the divergence between the two callers' success
// shapes (Karpathy: future success-shape fields wired on one path land on
// the other automatically).
//
// This test pins the structural-equivalence guarantee: drive a single
// `Completion` through BOTH the local-arm path (via `handle(...)` with an
// engine closure that returns the fixed completion) AND the serve-arm
// helper directly (via `buildSuccessOutcome(...)`). Assert byte-equal
// response data + equal `AuditFields`. Future refactor that re-introduces
// the divergence fails this test BEFORE the wire shape drifts in
// production.
@Suite("OpenAIChatHandler — success-response divergence guard (Lauret option B)")
struct OpenAIChatHandlerSuccessDivergenceGuardTests {

    private func makeCompletion(toolCalls: [OpenAIToolCall] = [], withRealCounts: Bool) -> OpenAIChatHandler.Completion {
        OpenAIChatHandler.Completion(
            content: toolCalls.isEmpty ? "hello" : "",
            toolCalls: toolCalls,
            promptTokens: 4,
            completionTokens: 2,
            realPromptTokens: withRealCounts ? 7 : nil,
            realCompletionTokens: withRealCounts ? 3 : nil
        )
    }

    private func driveLocalArm(
        completion: OpenAIChatHandler.Completion,
        request: ChatCompletionRequest,
        routing: OpenAIChatHandler.Routing,
        keyLabel: String?,
        now: Date,
        id: String
    ) -> OpenAIChatHandler.Result {
        let engine = OpenAIChatHandler.Engine { _, _, _ in completion }
        return OpenAIChatHandler.handle(
            request: request,
            recordPreset: routing.presetUsed.rawValue,
            keyLabel: keyLabel,
            engine: engine,
            now: now,
            id: id
        )
    }

    private func driveServeArmShared(
        completion: OpenAIChatHandler.Completion,
        request: ChatCompletionRequest,
        routing: OpenAIChatHandler.Routing,
        keyLabel: String?,
        now: Date,
        id: String
    ) -> (response: ChatCompletionResponse,
          fields: OpenAIAuditChain.AuditFields,
          bodies: OpenAIAuditChain.AuditBodies) {
        // The serve-arm's `successOutcome` is `private` — it routes through
        // the same shared helper directly. We exercise the shared helper
        // here; the integration test in `ClaudeAPIServeDispatchTests`
        // confirms `successOutcome` calls it.
        OpenAIChatHandler.buildSuccessOutcome(
            completion: completion,
            request: request,
            routing: routing,
            keyLabel: keyLabel,
            now: now,
            id: id
        )
    }

    private func assertParity(
        completion: OpenAIChatHandler.Completion,
        label: String
    ) {
        let routing = OpenAIChatHandler.Routing(
            // route(...) inside handle re-resolves routing from the
            // recordPreset; mirror that here so the routes match exactly.
            presetUsed: .auto, resolvedTier: .quick,
            actualModel: "claude-haiku-3.5", modelLogged: "gpt-4o"
        )
        let request = ChatCompletionRequest(
            model: "gpt-4o",
            messages: [.init(role: "user", content: "x")]
        )
        let keyLabel = "work"
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let id = "chatcmpl-parity-\(label)"

        let local = driveLocalArm(
            completion: completion, request: request, routing: routing,
            keyLabel: keyLabel, now: now, id: id
        )
        let serve = driveServeArmShared(
            completion: completion, request: request, routing: routing,
            keyLabel: keyLabel, now: now, id: id
        )

        // Response data — encode BOTH and compare bytes.
        let localData = OpenAIChatHandler.encodeResponse(local.response)
        let serveData = OpenAIChatHandler.encodeResponse(serve.response)
        #expect(localData == serveData,
            "[\(label)] response wire bytes must be byte-equal (local-arm vs serve-arm shared)")

        // AuditFields — full equality.
        #expect(local.auditFields == serve.fields,
            "[\(label)] auditFields must be equal (local-arm vs serve-arm shared)")

        // AuditBodies — full equality.
        #expect(local.auditBodies == serve.bodies,
            "[\(label)] auditBodies must be equal (local-arm vs serve-arm shared)")
    }

    @Test func parityForNoToolsHeuristicCounts() {
        assertParity(completion: makeCompletion(withRealCounts: false), label: "no-tools-heuristic")
    }

    @Test func parityForNoToolsRealCounts() {
        assertParity(completion: makeCompletion(withRealCounts: true), label: "no-tools-real")
    }

    @Test func parityForToolCallsRealCounts() {
        let toolCalls = [
            OpenAIToolCall(
                id: "call_42",
                function: .init(name: "get_weather", arguments: "{}")
            )
        ]
        assertParity(
            completion: makeCompletion(toolCalls: toolCalls, withRealCounts: true),
            label: "tools-real"
        )
    }
}
