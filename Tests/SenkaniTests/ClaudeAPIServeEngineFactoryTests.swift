import Testing
import Foundation
@testable import Core

// V.13b-4a — serve-path egress proxy-config factory + the structural
// "Direct HTTPS bypass: NONE" invariant. No live network: tests inspect the
// produced configuration / factory behavior, never connect.

private func tempPortFile(_ contents: String) -> String {
    let dir = NSTemporaryDirectory() + "v13b4a-\(UInt64.random(in: .min ... .max))"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/egress.port"
    try? contents.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

private func absentPortPath() -> String {
    NSTemporaryDirectory() + "v13b4a-absent-\(UInt64.random(in: .min ... .max))/egress.port"
}

@Suite("ClaudeAPIServeEngineFactory — egress proxy config + structural direct-refused (V.13b-4a)")
struct ClaudeAPIServeEngineFactoryTests {

    @Test func proxiedConfigurationSetsHttpsProxyKeysAtPort() {
        let config = ClaudeAPIServeEngineFactory.proxiedConfiguration(port: 49231)
        let dict = config.connectionProxyDictionary ?? [:]
        #expect(dict[kCFNetworkProxiesHTTPSEnable as String] as? Int == 1)
        #expect(dict[kCFNetworkProxiesHTTPSProxy as String] as? String == "127.0.0.1")
        #expect(dict[kCFNetworkProxiesHTTPSPort as String] as? Int == 49231)
        // HTTPS only — no plain-HTTP proxy is configured (the engine only
        // ever talks HTTPS to api.anthropic.com).
        #expect(dict[kCFNetworkProxiesHTTPEnable as String] == nil)
    }

    @Test func readEgressPortParsingMatrix() {
        #expect(ClaudeAPIServeEngineFactory.readEgressPort(path: tempPortFile("49231\n")) == 49231)
        #expect(ClaudeAPIServeEngineFactory.readEgressPort(path: tempPortFile("  5050  ")) == 5050)
        #expect(ClaudeAPIServeEngineFactory.readEgressPort(path: tempPortFile("0\n")) == nil)
        #expect(ClaudeAPIServeEngineFactory.readEgressPort(path: tempPortFile("-3")) == nil)
        #expect(ClaudeAPIServeEngineFactory.readEgressPort(path: tempPortFile("notaport")) == nil)
        #expect(ClaudeAPIServeEngineFactory.readEgressPort(path: absentPortPath()) == nil)
    }

    @Test func makeWithValidPortReturnsProxiedEngineNoThrow() throws {
        // A resolvable port yields a proxied engine (does NOT throw, does NOT
        // connect — construction only).
        _ = try ClaudeAPIServeEngineFactory.make(apiKey: "ak", portPath: tempPortFile("49231\n"))
    }

    @Test func makeWithMissingPortStructurallyRefusesNoDirectFallback() {
        var caught: ClaudeAPIServeEngineFactoryError?
        do {
            _ = try ClaudeAPIServeEngineFactory.make(apiKey: "ak-secret", portPath: absentPortPath())
            Issue.record("expected structural refusal — make() returned an engine on a missing egress port (DIRECT-BYPASS HOLE)")
        } catch let e as ClaudeAPIServeEngineFactoryError {
            caught = e
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        guard case .egressDaemonUnavailable = caught else {
            Issue.record("expected .egressDaemonUnavailable, got \(String(describing: caught))"); return
        }
        // Refusal message is operator-actionable (path/hint) and never leaks
        // the api key.
        #expect(!String(describing: caught!).contains("ak-secret"))
    }
}

@Suite("ClaudeAPIChatEngine — per-request timeout seam (V.13b-4a)", .serialized, .urlProtocolGate)
struct ClaudeAPIChatEngineTimeoutSeamTests {

    private static let url = URL(string: "https://api.anthropic.com/v1/messages")!

    // The request is built ONCE in chat() with timeoutInterval set before the
    // retry loop, then the same value-type URLRequest is reused on every
    // attempt — so a single-attempt assertion proves the per-attempt deadline
    // by construction (no retry-specific path can lose it).
    @Test func requestTimeoutSetOnFiredRequest() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """
        MockURLProtocol.register(url: Self.url, status: 200, body: Data(body.utf8))
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let engine = ClaudeAPIChatEngine(
            apiKey: "ak", session: URLSession(configuration: cfg), endpoint: Self.url,
            sleeper: { _ in }, requestTimeout: 12)
        _ = try await engine.chat(model: "claude-haiku-3.5", messages: [.init(role: "user", content: "hi")], tools: [])
        #expect(MockURLProtocol.lastRequest?.timeoutInterval == 12)
    }

    @Test func noRequestTimeoutLeavesURLSessionDefault() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = """
        {"id":"x","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """
        MockURLProtocol.register(url: Self.url, status: 200, body: Data(body.utf8))
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        let engine = ClaudeAPIChatEngine(
            apiKey: "ak", session: URLSession(configuration: cfg), endpoint: Self.url,
            sleeper: { _ in })  // requestTimeout defaults nil
        _ = try await engine.chat(model: "claude-haiku-3.5", messages: [.init(role: "user", content: "hi")], tools: [])
        // Default URLRequest timeout is 60s.
        #expect(MockURLProtocol.lastRequest?.timeoutInterval == 60)
    }
}
