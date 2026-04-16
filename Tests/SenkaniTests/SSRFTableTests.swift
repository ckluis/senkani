import Testing
import Foundation
@testable import MCPServer

/// Bach G3: parameterized table-driven expansion of the SSRF parser.
/// Swift Testing's `@Test(arguments:)` gives us parametric coverage
/// without a property-based framework dep. True randomized fuzz remains
/// a follow-up; this catches every boundary case the author DID think
/// of, exhaustively.
@Suite("SSRFTable")
struct SSRFTableTests {

    // MARK: - Must be private (rejected)

    static let privateHosts: [String] = [
        // RFC 1918 10/8 — boundary cases
        "10.0.0.0", "10.0.0.1", "10.255.255.255",
        // 172.16/12 — boundary cases
        "172.16.0.0", "172.16.0.1",
        "172.23.45.67",
        "172.31.0.0", "172.31.255.255",
        // 192.168/16 — boundary cases
        "192.168.0.0", "192.168.0.1", "192.168.255.255",
        // Link-local 169.254/16 — including cloud metadata
        "169.254.0.0", "169.254.169.254", "169.254.255.255",
        // CGNAT 100.64/10 — boundary cases
        "100.64.0.0", "100.100.100.100", "100.127.255.255",
        // Reserved / unspecified
        "0.0.0.0", "0.1.2.3",
        // IPv4 multicast + reserved
        "224.0.0.0", "224.0.0.1", "239.255.255.255",
        "240.0.0.0", "255.255.255.255",
        // IPv6 link-local fe80::/10
        "fe80::", "fe80::1", "febf::1",
        // IPv6 ULA fc00::/7
        "fc00::", "fcff::1", "fd00::", "fdff::ffff:ffff",
        // IPv6 multicast ff00::/8
        "ff00::", "ff02::1", "ff0e::1:2:3:4",
        // IPv6 unspecified
        "::",
        // IPv4-mapped IPv6 with private payloads
        "::ffff:10.0.0.1", "::ffff:169.254.169.254",
        "::ffff:172.16.0.1", "::ffff:192.168.1.1",
        "::ffff:100.64.0.1",
        // IPv4-compatible IPv6 (deprecated) — everything except ::1 blocks
        "::10.0.0.1", "::1.2.3.4", "::0.0.0.2",
        // Bracketed forms of the above — should be stripped then checked
        "[::]", "[fe80::1]", "[::ffff:10.0.0.1]",
    ]

    // MARK: - Must be public (allowed)

    static let publicHosts: [String] = [
        // Well-known public DNS
        "8.8.8.8", "1.1.1.1", "9.9.9.9",
        // Random public IPv4 addresses
        "93.184.216.34", // example.com historical
        "142.250.80.46",
        "216.58.214.174",
        // 172 below 16 and above 31 — not private
        "172.15.255.255", "172.32.0.0",
        // 192.168 neighborhood — only 168 is private
        "192.167.255.255", "192.169.0.0",
        // 100 neighborhood — only 64..127 is CGNAT
        "100.63.255.255", "100.128.0.0",
        // 169 neighborhood — only 254 is link-local
        "169.253.255.255", "169.255.0.0",
        // Public IPv6
        "2606:4700:4700::1111", "2001:4860:4860::8888",
        // IPv4-mapped IPv6 with PUBLIC payloads
        "::ffff:8.8.8.8", "::ffff:1.1.1.1",
        // Loopback — intentionally NOT private per developer use case
        "127.0.0.1", "127.255.255.255", "::1", "[::1]",
        "::ffff:127.0.0.1",
    ]

    // MARK: - Must fall through (not IP literals)

    static let hostnames: [String] = [
        "example.com",
        "internal.company.local",
        "api.github.com",
        "localhost",
        "sub.domain.example",
    ]

    // MARK: - Parameterized tests

    @Test("isPrivateHost recognizes every private literal",
          arguments: privateHosts)
    func privateHostsRejected(host: String) {
        #expect(isPrivateHost(host), "\(host) should be classified private")
    }

    @Test("isPrivateHost allows every public literal",
          arguments: publicHosts)
    func publicHostsAllowed(host: String) {
        #expect(!isPrivateHost(host), "\(host) should be classified public")
    }

    @Test("isPrivateHost returns false for hostnames (DNS deferred)",
          arguments: hostnames)
    func hostnamesFallThrough(host: String) {
        // `isPrivateHost` is the string-level check; hostnames fall through
        // so the caller (hostResolvesToPrivate) must resolve and recheck.
        #expect(!isPrivateHost(host),
                "\(host) is not an IP literal — must return false so caller runs DNS")
    }

    // MARK: - Fast-path consistency

    @Test func hostResolvesToPrivateAgreesForLiterals() {
        for h in Self.privateHosts {
            #expect(hostResolvesToPrivate(h),
                    "hostResolvesToPrivate must agree with isPrivateHost for \(h)")
        }
        for h in Self.publicHosts {
            #expect(!hostResolvesToPrivate(h),
                    "hostResolvesToPrivate must agree with isPrivateHost for \(h)")
        }
    }

    // MARK: - Unresolvable names fail closed

    @Test func unresolvableHostnameFailsClosed() {
        // TLD .invalid is reserved by RFC 2606 — must never resolve.
        #expect(hostResolvesToPrivate("this-should-never-resolve.invalid"),
                "unresolvable hostname must fail closed (treated private)")
    }
}
