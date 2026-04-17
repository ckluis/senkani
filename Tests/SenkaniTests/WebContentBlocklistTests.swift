import Testing
import Foundation
import WebKit
@testable import MCPServer

/// F2 (Schneier re-audit 2026-04-16) — subresource blocklist tests.
///
/// `ruleWouldBlock` is a mirror of WebKit's url-filter application via
/// `NSRegularExpression`. The authoritative path (`compile()` returning a
/// live `WKContentRuleList`) is covered by the integration test at the
/// bottom of this file; the mirror tests verify coverage of every
/// blocked range without depending on WebKit's async compilation.
@Suite("WebContentBlocklist")
struct WebContentBlocklistTests {

    // MARK: - JSON sanity

    @Test func rulesJSONIsValid() throws {
        let data = try #require(WebContentBlocklist.rulesJSON.data(using: .utf8))
        let obj = try JSONSerialization.jsonObject(with: data)
        let arr = try #require(obj as? [Any], "rulesJSON must be a top-level array")
        #expect(!arr.isEmpty, "rules must be non-empty")
        for item in arr {
            let rule = try #require(item as? [String: Any])
            let trigger = try #require(rule["trigger"] as? [String: Any])
            #expect(trigger["url-filter"] as? String != nil)
            let action = try #require(rule["action"] as? [String: Any])
            #expect((action["type"] as? String) == "block")
        }
    }

    // MARK: - Must block

    @Test func blocksRFC1918ClassA() {
        for url in ["http://10.0.0.1/", "https://10.255.255.1/admin",
                    "http://10.1.2.3/api", "http://user:pass@10.0.0.1/"] {
            #expect(WebContentBlocklist.ruleWouldBlock(url), "\(url) should be blocked")
        }
    }

    @Test func blocksRFC1918ClassB() {
        for url in ["http://172.16.0.1/", "https://172.23.45.67/",
                    "http://172.31.255.255/admin"] {
            #expect(WebContentBlocklist.ruleWouldBlock(url), "\(url) should be blocked")
        }
    }

    @Test func blocksRFC1918ClassC() {
        for url in ["http://192.168.1.1/", "https://192.168.255.255/"] {
            #expect(WebContentBlocklist.ruleWouldBlock(url), "\(url) should be blocked")
        }
    }

    @Test func blocksLinkLocal() {
        for url in ["http://169.254.169.254/latest/meta-data/",
                    "http://169.254.0.1/"] {
            #expect(WebContentBlocklist.ruleWouldBlock(url),
                    "\(url) (link-local / cloud metadata) should be blocked")
        }
    }

    @Test func blocksCGNAT() {
        for url in ["http://100.64.0.0/", "http://100.100.100.100/",
                    "http://100.127.255.255/"] {
            #expect(WebContentBlocklist.ruleWouldBlock(url), "\(url) should be blocked")
        }
    }

    @Test func blocksIPv6ULA() {
        for url in ["http://[fc00::1]/", "http://[fdff::ffff]/"] {
            #expect(WebContentBlocklist.ruleWouldBlock(url), "\(url) should be blocked")
        }
    }

    @Test func blocksIPv6LinkLocal() {
        for url in ["http://[fe80::1]/", "http://[fe80::abcd:1234]/"] {
            #expect(WebContentBlocklist.ruleWouldBlock(url), "\(url) should be blocked")
        }
    }

    @Test func blocksIPv6Multicast() {
        for url in ["http://[ff00::1]/", "http://[ff02::1]/"] {
            #expect(WebContentBlocklist.ruleWouldBlock(url), "\(url) should be blocked")
        }
    }

    @Test func blocksIPv4MappedIPv6Private() {
        for url in ["http://[::ffff:10.0.0.1]/",
                    "http://[::ffff:169.254.169.254]/",
                    "http://[::ffff:172.16.0.1]/",
                    "http://[::ffff:192.168.1.1]/"] {
            #expect(WebContentBlocklist.ruleWouldBlock(url), "\(url) should be blocked")
        }
    }

    // MARK: - Must NOT block

    @Test func allowsPublicIPv4() {
        for url in ["http://8.8.8.8/", "https://1.1.1.1/", "http://93.184.216.34/",
                    "http://172.15.255.255/", "http://172.32.0.0/",
                    "http://192.167.255.255/", "http://192.169.0.0/",
                    "http://100.63.255.255/", "http://100.128.0.0/",
                    "http://169.253.255.255/", "http://169.255.0.0/"] {
            #expect(!WebContentBlocklist.ruleWouldBlock(url),
                    "\(url) must be allowed (public neighborhood of private ranges)")
        }
    }

    @Test func allowsLoopback() {
        for url in ["http://127.0.0.1/", "http://127.0.0.1:8080/",
                    "http://localhost/", "http://[::1]/"] {
            #expect(!WebContentBlocklist.ruleWouldBlock(url),
                    "\(url) must be allowed (developer loopback)")
        }
    }

    @Test func allowsPublicHostname() {
        for url in ["https://example.com/", "https://api.github.com/",
                    "https://raw.githubusercontent.com/foo/bar/main/README.md"] {
            #expect(!WebContentBlocklist.ruleWouldBlock(url),
                    "\(url) must be allowed")
        }
    }

    @Test func allowsIPv4MappedPublic() {
        for url in ["http://[::ffff:8.8.8.8]/", "http://[::ffff:1.1.1.1]/"] {
            #expect(!WebContentBlocklist.ruleWouldBlock(url),
                    "\(url) must be allowed (public IPv4-mapped IPv6)")
        }
    }

    // MARK: - Bypass env

    @Test func bypassEnvParsesOn() {
        let prior = ProcessInfo.processInfo.environment["SENKANI_WEB_ALLOW_PRIVATE"]
        setenv("SENKANI_WEB_ALLOW_PRIVATE", "on", 1)
        defer {
            if let p = prior { setenv("SENKANI_WEB_ALLOW_PRIVATE", p, 1) }
            else { unsetenv("SENKANI_WEB_ALLOW_PRIVATE") }
        }
        #expect(WebContentBlocklist.bypassEnabled)
    }

    @Test func bypassEnvUnsetIsOff() {
        let prior = ProcessInfo.processInfo.environment["SENKANI_WEB_ALLOW_PRIVATE"]
        unsetenv("SENKANI_WEB_ALLOW_PRIVATE")
        defer {
            if let p = prior { setenv("SENKANI_WEB_ALLOW_PRIVATE", p, 1) }
        }
        #expect(!WebContentBlocklist.bypassEnabled)
    }
}

// MARK: - Integration — compile against real WebKit

@Suite("WebContentBlocklist — WebKit integration")
struct WebContentBlocklistIntegrationTests {

    /// Verifies our JSON parses through WebKit's actual compiler. If
    /// WebKit's `url-filter` subset rejected any of our patterns, compile
    /// would return nil here and the test would fail — surfacing the
    /// issue before it quietly disables the runtime filter in production.
    @Test @MainActor func rulesCompileUnderWebKit() async {
        let list = await WebContentBlocklist.compile()
        #expect(list != nil,
                "WKContentRuleList must compile — if this fails, inspect stderr for the WebKit error and fix the rule regex subset compatibility")
    }
}
