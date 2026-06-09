import Testing
import Foundation
import Network
import BrowserPane
import Core

/// Behavioral happy-path coverage for the two pure `public static`
/// egress helpers on `BrowserPaneRunner` —
/// `makeProxyConfiguration(proxyURL:)` and
/// `writeEgressOverridePolicy(targetURL:proxyURL:)`.
///
/// The companion `BrowserPaneRunnerEgressWiringTests` suite covers the
/// NIL no-op contract via a source-shape grep (proxyURL=nil ⇒ nil,
/// helper presence, the `proxyConfigurations` wiring text). This suite
/// closes the other half: when fed VALID inputs the helpers actually
/// produce a `ProxyConfiguration` and a loadable override-policy file
/// containing the expected same-origin ALLOW rule. These exercise the
/// compiled symbols directly (the `SenkaniTests` target links both
/// `BrowserPane` and `Core`), not the source text — so a future refactor
/// that keeps the grep'd strings but breaks the runtime shape is caught
/// here.
///
/// Scope note: the FULL runtime acceptance (live WKWebView traffic
/// through a running EgressProxy daemon, daemon-down falsifier) stays
/// operator-gated in
/// `process-gap-browserpanerunner-egress-runtime-validation-2026-05-22`
/// — it needs a real app + real egress and cannot run under `swift test`.
@Suite("BrowserPaneRunnerEgress behavioral helpers — happy path")
struct BrowserPaneRunnerEgressBehaviorTests {

    @Test("makeProxyConfiguration returns a non-nil ProxyConfiguration for a valid host:port proxy URL")
    func makeProxyConfigurationHappyPath() throws {
        let proxyURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let config: ProxyConfiguration? =
            BrowserPaneRunner.makeProxyConfiguration(proxyURL: proxyURL)
        // The helper extracts host + port (8080 here, not the :80
        // default) and builds an HTTP-CONNECT proxy. A valid URL with a
        // resolvable host and a port in the UInt16 range must yield a
        // configuration — never nil.
        #expect(config != nil,
                "makeProxyConfiguration must return a non-nil ProxyConfiguration for http://127.0.0.1:8080 (host + port both present and valid)")
    }

    @Test("makeProxyConfiguration accepts a host with no explicit port (falls back to :80)")
    func makeProxyConfigurationDefaultPort() throws {
        // url.port is nil here; the helper falls back to UInt16(80),
        // which is a valid NWEndpoint.Port — so the happy path still
        // produces a non-nil configuration.
        let proxyURL = try #require(URL(string: "http://proxy.local"))
        let config = BrowserPaneRunner.makeProxyConfiguration(proxyURL: proxyURL)
        #expect(config != nil,
                "makeProxyConfiguration must return a non-nil ProxyConfiguration when no port is given (defaults to :80)")
    }

    @Test("writeEgressOverridePolicy writes a file that EgressPolicy.load decodes to a same-origin ALLOW rule for the target's origin")
    func writeEgressOverridePolicyHappyPath() throws {
        let proxyURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let targetURL = "https://example.com/some/path?q=1"

        let path = try #require(
            BrowserPaneRunner.writeEgressOverridePolicy(
                targetURL: targetURL,
                proxyURL: proxyURL
            ),
            "writeEgressOverridePolicy must return a temp path when given a valid https target + a valid proxy URL"
        )
        // Clean up the temp file no matter how the assertions go — the
        // helper's own caller (BrowserPaneRunner.run) cleans up via a
        // `defer`, and this test owns the file it created.
        defer { try? FileManager.default.removeItem(atPath: path) }

        // The file must actually exist on disk and sit under the temp
        // directory with the canonical `senkani-egress-override-` prefix.
        #expect(FileManager.default.fileExists(atPath: path),
                "the returned path must point at a file that was written to disk")
        #expect((path as NSString).lastPathComponent.hasPrefix("senkani-egress-override-"),
                "the override file must use the senkani-egress-override-<uuid>.json filename pattern")

        // Load the policy back through the SAME on-disk wire format the
        // EgressProxy daemon reads. A clean parse means degradedReason
        // is nil (a malformed file would surface a parse-failure reason).
        let (policy, degradedReason) = EgressPolicy.load(from: path)
        #expect(degradedReason == nil,
                "the written override file must parse cleanly — a non-nil degradedReason means the wire JSON is malformed")

        // sameOriginAllowlist applies the rule to EVERY PaneMode, so the
        // decoded policy must carry the allow rule for the .general
        // engine (and the others). Assert against the engine the daemon
        // resolves by default.
        let engine = policy.engine(for: .general)
        let allowRule = try #require(
            engine.rules.first { $0.id == "validate_browser_same_origin" },
            "the decoded policy must contain the same-origin allow rule produced by EgressPolicy.sameOriginAllowlist(targetURL:)"
        )
        #expect(allowRule.decision == .allow,
                "the same-origin rule must be an ALLOW rule")
        #expect(allowRule.mode == .suffix,
                "the same-origin rule must use suffix matching (origin + its subdomains)")
        #expect(allowRule.pattern == "example.com",
                "the rule pattern must be the normalized host of the target origin (https://example.com/... ⇒ example.com)")

        // The rule must be present across ALL pane modes — the
        // allowlist is pane-mode-agnostic for validation dispatch.
        for mode in PaneMode.allCases {
            let modeEngine = policy.engine(for: mode)
            #expect(modeEngine.rules.contains { $0.id == "validate_browser_same_origin" && $0.decision == .allow },
                    "every PaneMode engine must carry the same-origin allow rule (mode=\(mode.rawValue))")
        }
    }
}
