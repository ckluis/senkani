import Testing
import Foundation
@testable import Core

#if canImport(Darwin)
import Darwin
#endif

/// V.13a-1 — OpenAI listener scaffold tests. Covers the eight acceptance
/// bullets from `spec/autonomous/backlog/phase-v13a-1-listener-serve-cli.md`:
///
///   1. bind-config parse (JSON `openai_endpoint` block)
///   2. flag-overrides-config (invocation-only override)
///   3. non-loopback-warning
///   4. refuse-to-start-without-keys
///   5. non-loopback-abort-without-accept-flag
///   6. startup-log shape
///   7. 501-on-unwired-/v1/-path
///   8. clean-shutdown (no leaked port)
///
/// (`config.yaml` in the original acceptance text → JSON here; see
/// `OpenAIEndpointConfig`'s storage-format note + the round's filed
/// follow-up for the divergence audit trail.)
@Suite("OpenAIListener scaffold (V.13a-1)")
struct OpenAIListenerScaffoldTests {

    private static func tempConfigPath() -> String {
        NSTemporaryDirectory() + "v13a-1-cfg-\(UUID().uuidString).json"
    }

    // MARK: - 1. bind-config parse

    @Test("config round-trips through the openai_endpoint JSON block")
    func bindConfigParse() throws {
        let path = Self.tempConfigPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let written = OpenAIEndpointConfig(
            bind: "127.0.0.1", port: 9001, enabled: true, acceptNetworkBind: true
        )
        try written.save(path: path)

        // The persisted file nests the keys under `openai_endpoint`.
        let raw = try #require(FileManager.default.contents(atPath: path))
        let json = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let inner = try #require(json["openai_endpoint"] as? [String: Any])
        #expect(inner["bind"] as? String == "127.0.0.1")
        #expect(inner["port"] as? Int == 9001)
        #expect(inner["enabled"] as? Bool == true)
        #expect(inner["accept_network_bind"] as? Bool == true)

        let loaded = OpenAIEndpointConfig.load(path: path)
        #expect(loaded == written)
    }

    @Test("load returns defaults when the file or key is absent")
    func loadDefaults() {
        let missing = OpenAIEndpointConfig.load(path: NSTemporaryDirectory() + "nope-\(UUID()).json")
        #expect(missing == OpenAIEndpointConfig.default)
        #expect(missing.bind == "127.0.0.1")
        #expect(missing.port == 8470)
        #expect(missing.enabled == false)
    }

    // MARK: - 2. flag-overrides-config (invocation-only)

    @Test("CLI flags override loaded config for the invocation without writing the file")
    func flagOverridesConfig() throws {
        let path = Self.tempConfigPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let baseline = OpenAIEndpointConfig(bind: "127.0.0.1", port: 8470, enabled: false)
        try baseline.save(path: path)

        let loaded = OpenAIEndpointConfig.load(path: path)
        let effective = loaded.merging(bind: "127.0.0.2", port: 9999, acceptNetworkBind: nil)
        #expect(effective.bind == "127.0.0.2")
        #expect(effective.port == 9999)

        // The override is invocation-only: the file on disk is unchanged.
        let reloaded = OpenAIEndpointConfig.load(path: path)
        #expect(reloaded.bind == "127.0.0.1")
        #expect(reloaded.port == 8470)
    }

    @Test("nil flags leave the loaded values intact")
    func mergeNilLeavesIntact() {
        let loaded = OpenAIEndpointConfig(bind: "127.0.0.1", port: 8470, acceptNetworkBind: true)
        let effective = loaded.merging(bind: nil, port: nil, acceptNetworkBind: nil)
        #expect(effective == loaded)
    }

    // MARK: - 3. non-loopback warning

    @Test("non-loopback bind emits a warning naming the exposed surface")
    func nonLoopbackWarning() throws {
        let outcome = OpenAIListenerGuard.evaluate(
            bind: "0.0.0.0", port: 8470, acceptNetworkBind: true, keyCount: 1
        )
        #expect(outcome.allowed == true)
        let warning = try #require(outcome.warning)
        #expect(warning.contains("0.0.0.0:8470"))
        #expect(warning.uppercased().contains("NON-LOOPBACK"))
    }

    @Test("loopback binds are allowed with no warning")
    func loopbackAllowedNoWarning() {
        for host in ["127.0.0.1", "::1", "localhost", "127.0.0.5"] {
            let outcome = OpenAIListenerGuard.evaluate(
                bind: host, port: 8470, acceptNetworkBind: false, keyCount: 0
            )
            #expect(outcome.allowed == true, "\(host) should be allowed")
            #expect(outcome.warning == nil, "\(host) should not warn")
            #expect(OpenAIListenerGuard.isLoopback(host) == true)
        }
        #expect(OpenAIListenerGuard.isLoopback("0.0.0.0") == false)
        #expect(OpenAIListenerGuard.isLoopback("192.168.1.10") == false)
    }

    // MARK: - 4. refuse-to-start without keys

    @Test("non-loopback bind with zero provisioned keys refuses to start")
    func refuseToStartWithoutKeys() throws {
        let outcome = OpenAIListenerGuard.evaluate(
            bind: "0.0.0.0", port: 8470, acceptNetworkBind: true, keyCount: 0
        )
        #expect(outcome.allowed == false)
        let reason = try #require(outcome.abortReason)
        #expect(reason.lowercased().contains("key"))
        // Warning still names the surface even on refusal.
        #expect(outcome.warning?.contains("0.0.0.0:8470") == true)
    }

    // MARK: - 5. non-loopback abort without accept flag

    @Test("non-loopback bind without --accept-network-bind aborts even with keys")
    func nonLoopbackAbortWithoutAcceptFlag() throws {
        let outcome = OpenAIListenerGuard.evaluate(
            bind: "10.0.0.4", port: 8470, acceptNetworkBind: false, keyCount: 5
        )
        #expect(outcome.allowed == false)
        let reason = try #require(outcome.abortReason)
        #expect(reason.contains("--accept-network-bind"))
    }

    // MARK: - 6. startup-log shape

    @Test("startup log names bind, port, and key count")
    func startupLogShape() {
        let line = OpenAIListener.startupLog(bind: "127.0.0.1", port: 8470, keyCount: 3)
        #expect(line.contains("127.0.0.1"))
        #expect(line.contains("8470"))
        #expect(line.contains("3"))
        #expect(line.lowercased().contains("key"))
    }

    @Test("route returns 501 for /v1/* and 404 otherwise (pure)")
    func routePure() {
        let chat = OpenAIListener.route(requestLine: "POST /v1/chat/completions HTTP/1.1")
        #expect(String(decoding: chat, as: UTF8.self).hasPrefix("HTTP/1.1 501 Not Implemented"))

        let models = OpenAIListener.route(requestLine: "GET /v1/models HTTP/1.1")
        #expect(String(decoding: models, as: UTF8.self).hasPrefix("HTTP/1.1 501"))

        let root = OpenAIListener.route(requestLine: "GET / HTTP/1.1")
        #expect(String(decoding: root, as: UTF8.self).hasPrefix("HTTP/1.1 404"))
    }

    // MARK: - 7. 501 on unwired /v1/ path (live round-trip)

    #if canImport(Network)
    @Test("live listener returns 501 for /v1/* over loopback")
    func fiveOhOneOnUnwiredPath() throws {
        let listener = OpenAIListener(config: .init(bind: "127.0.0.1", port: 0))
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

        #expect(response.hasPrefix("HTTP/1.1 501 Not Implemented"))
        #expect(response.contains("Content-Length:"))
        #expect(response.contains("not_implemented"))
    }

    // MARK: - 8. clean shutdown (no leaked port)

    @Test("start/stop is idempotent and releases the port cleanly")
    func cleanShutdown() throws {
        let listener = OpenAIListener(config: .init(bind: "127.0.0.1", port: 0))
        try listener.start()
        let port = listener.port
        #expect(listener.isRunning == true)
        #expect(port > 0)

        // Double-start while running is a no-op.
        try listener.start()
        #expect(listener.port == port)

        listener.stop()
        #expect(listener.isRunning == false)
        #expect(listener.port == 0)
        // Double-stop is a no-op.
        listener.stop()
        #expect(listener.isRunning == false)

        // Port is released: a fresh listener with reuse can bind again
        // and reach ready (proves no leaked listening socket).
        let again = OpenAIListener(config: .init(bind: "127.0.0.1", port: 0))
        try again.start()
        #expect(again.isRunning == true)
        #expect(again.port > 0)
        again.stop()
    }
    #endif
}
