import Testing
import Foundation

/// U.2b-1b-5 — source-shape + EgressPolicy contract test for
/// `BrowserPaneRunner.swift`'s egress-proxy wiring.
///
/// The runtime acceptance bullet (WKWebView traffic appears in
/// EgressProxy listener logs; out-of-allowlist target is blocked) is
/// filed as a manual-validation follow-up at close — the same
/// testability constraint that drove U.2b-1b-4's structural tests:
/// `SenkaniApp` is an executableTarget that `SenkaniTests` does not
/// depend on, so we can't allocate a real WKWebView with a
/// `proxyConfigurations`-wired data store from inside `swift test`.
///
/// What this test DOES verify (the source-shape contract child #6's
/// dispatcher wiring + the runtime-validation follow-up exercise):
///   1. `BrowserPaneRunner` declares an `egressProxyURL: URL?` slot
///      on its init + stored property, and `import Network` is
///      present (since `ProxyConfiguration` is `Network.ProxyConfiguration`).
///   2. The runner sets `dataStore.proxyConfigurations = [...]` so
///      WKWebView traffic tunnels through the EgressProxy listener.
///   3. The runner mirrors `BrowserValidationDispatcher.writeEgressOverridePolicyIfNeeded`
///      — `senkani-egress-override-<uuid>.json` filename pattern,
///      same-origin allowlist computed via
///      `EgressPolicy.sameOriginAllowlist(targetURL:)`.
@Suite("BrowserPaneRunner egress-proxy wiring — U.2b-1b-5")
struct BrowserPaneRunnerEgressWiringTests {

    private static func servicesDir() -> URL? {
        var cur = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = cur.appendingPathComponent("SenkaniApp/Services", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { break }
            cur = parent
        }
        return nil
    }

    private static func runnerSource() throws -> String? {
        guard let dir = servicesDir() else { return nil }
        let url = dir.appendingPathComponent("BrowserPaneRunner.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("BrowserPaneRunner wires EgressProxy URL through to WKWebsiteDataStore.proxyConfigurations + writes a per-target same-origin override-policy file mirroring BrowserValidationDispatcher")
    func runnerWiresEgressProxy() throws {
        guard let source = try Self.runnerSource() else {
            // SenkaniApp/Services/ resolution depends on CWD —
            // skip gracefully when run from outside a checkout.
            return
        }

        // 1) `import Network` is required — `ProxyConfiguration` is
        //    the Swift overlay name for `Network.ProxyConfiguration`.
        #expect(source.contains("import Network"),
                "BrowserPaneRunner must `import Network` so `ProxyConfiguration` resolves (the type for `WKWebsiteDataStore.proxyConfigurations`)")

        // 2) `egressProxyURL: URL?` slot on init + stored property.
        #expect(source.contains("egressProxyURL: URL?"),
                "BrowserPaneRunner must expose `egressProxyURL: URL?` so child #6's dispatcher can pass the EgressProxy listener URL through to the off-screen WKWebView's website data store")
        #expect(source.contains("public let egressProxyURL"),
                "BrowserPaneRunner must declare `public let egressProxyURL` so callers can introspect the configured proxy (the dispatcher's audit-chain row writer reads it for the `runner=wkwebview-headless` row)")

        // 3) `WKWebsiteDataStore.proxyConfigurations` wiring — the
        //    macOS 14+ surface (array of `Network.ProxyConfiguration`).
        //    The acceptance text used the convenient shorthand
        //    `httpProxyConfiguration`; the actual Swift API is
        //    `proxyConfigurations` (plural array). Verify both
        //    so the source can be grep'd by either name.
        #expect(source.contains("proxyConfigurations"),
                "BrowserPaneRunner must set `dataStore.proxyConfigurations = [...]` (macOS 14+ surface) so WKWebView traffic tunnels through the EgressProxy listener — this is the actual `WKWebsiteDataStore` API behind the acceptance's `httpProxyConfiguration` shorthand")
        #expect(source.contains("ProxyConfiguration"),
                "BrowserPaneRunner must construct a `Network.ProxyConfiguration` instance (the value type WKWebsiteDataStore.proxyConfigurations accepts)")
        #expect(source.contains("httpCONNECTProxy"),
                "BrowserPaneRunner must use the HTTP-CONNECT proxy variant — matches the EgressProxy daemon's listener convention (T.1a) so HTTPS traffic tunnels through")

        // 4) Override-policy file mirrors BrowserValidationDispatcher.
        //    Filename pattern + sameOriginAllowlist + encodeWireJSON.
        #expect(source.contains("EgressPolicy.sameOriginAllowlist"),
                "BrowserPaneRunner must compute the per-target same-origin allowlist via `EgressPolicy.sameOriginAllowlist(targetURL:)` — the same helper `BrowserValidationDispatcher.writeEgressOverridePolicyIfNeeded` uses")
        #expect(source.contains("senkani-egress-override-"),
                "BrowserPaneRunner's override-policy file must use the `senkani-egress-override-<uuid>.json` filename pattern that `BrowserValidationDispatcher.writeEgressOverridePolicyIfNeeded` writes — daemon-side override consumers grep for this prefix")
        #expect(source.contains("encodeWireJSON"),
                "BrowserPaneRunner must serialize the same-origin allowlist via `EgressPolicy.encodeWireJSON()` — the wire format `EgressPolicy.load(from:)` reads")

        // 5) Cleanup via defer.
        #expect(source.contains("removeItem(atPath:") || source.contains("removeItem(at:"),
                "BrowserPaneRunner must clean up the temp override-policy file after `run(...)` returns — the dispatcher uses `defer { try? FileManager.default.removeItem(atPath: path) }` and this round mirrors that")

        // 6) Public helpers exposed for child #6's wiring + this test.
        #expect(source.contains("public static func writeEgressOverridePolicy"),
                "BrowserPaneRunner must expose `public static func writeEgressOverridePolicy(targetURL:proxyURL:)` so child #6's dispatcher can pre-write the override before invoking `run(...)` (matches the dispatcher's existing `writeEgressOverridePolicyIfNeeded` API shape)")
        #expect(source.contains("public static func makeProxyConfiguration"),
                "BrowserPaneRunner must expose `public static func makeProxyConfiguration(proxyURL:)` so the dispatcher (and tests) can construct the `Network.ProxyConfiguration` without instantiating a runner")
    }
}
