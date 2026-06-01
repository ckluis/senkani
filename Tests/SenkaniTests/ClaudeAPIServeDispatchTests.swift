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
