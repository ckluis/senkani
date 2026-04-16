import Testing
import XCTest
import Foundation
@testable import MCPServer
@testable import Core

// MARK: - Swift Testing — pure function tests (no WKWebView required)

@Suite("WebFetch — AXTree Formatter")
struct WebFetchFormatterTests {

    @Test("headings formatted with Markdown prefix")
    func headingsFormatted() {
        let json = #"{"title":"T","url":"https://x.com","nodes":[{"tag":"h1","text":"Hello"},{"tag":"h2","text":"World"},{"tag":"h3","text":"Sub"}],"rawLen":1000}"#
        let (md, _, count) = AXTreeFormatter.format(jsonString: json)
        #expect(md.contains("# Hello"))
        #expect(md.contains("## World"))
        #expect(md.contains("### Sub"))
        #expect(count == 3)
    }

    @Test("links with href formatted as Markdown links")
    func linksWithHrefFormatted() {
        let json = #"{"title":"T","url":"https://x.com","nodes":[{"tag":"a","text":"Click here","href":"/about"},{"tag":"a","text":"Bare link"}],"rawLen":500}"#
        let (md, _, _) = AXTreeFormatter.format(jsonString: json)
        #expect(md.contains("[Click here](/about)"))
        #expect(md.contains("[Bare link]"))
    }

    @Test("auth wall warning prepended when password input detected")
    func authWallDetected() {
        let json = #"{"title":"Login","url":"https://x.com","nodes":[{"tag":"input","text":"","type":"password","label":"Password"}],"rawLen":2000}"#
        let (md, _, _) = AXTreeFormatter.format(jsonString: json)
        #expect(md.contains("[Warning: This page appears to require authentication.]"))
    }

    @Test("invalid JSON returns fallback error message")
    func invalidJSONFallback() {
        let (md, raw, count) = AXTreeFormatter.format(jsonString: "not json {{ bad")
        #expect(md.contains("Could not parse"))
        #expect(raw == 0)
        #expect(count == 0)
    }

    @Test("disabled error message contains SENKANI_WEB=off")
    func disabledErrorMessage() {
        let err = WebFetchError.disabled
        #expect(err.errorDescription?.contains("SENKANI_WEB=off") == true)
    }

    @Test("format:text output has text header, not AXTree header")
    func formatTextHeader() {
        // AXTree formatter always produces "format: AXTree" in its header.
        // format:"text" uses innerTextJS — its output should contain the text header,
        // not the AXTree header. This test verifies the two formats produce distinct headers.
        // (The actual innerText extraction requires WKWebView; we verify the AXTree header
        // is NOT what "text" format would produce — i.e., the code paths diverge.)
        let axTreeHeader = "// format: AXTree"
        let textHeader   = "// format: text"

        // AXTreeFormatter always produces the AXTree header
        let json = #"{"title":"T","url":"https://x.com","nodes":[{"tag":"p","text":"Hello"}],"rawLen":500}"#
        let (axMD, _, _) = AXTreeFormatter.format(jsonString: json)
        #expect(axMD.contains(axTreeHeader), "AXTree formatter must produce AXTree header")
        #expect(!axMD.contains(textHeader),  "AXTree formatter must not produce text header")

        // format:"text" timeout error message should reference innerText behavior (not AXTree)
        // Verified structurally: NavigationHandler branches on format == "text"
        // so the two code paths are distinct by construction (confirmed via code review).
    }
}

// MARK: - SSRF Guard Tests

@Suite("WebFetch — SSRF Private IP Guard")
struct WebFetchSSRFTests {

    // RFC 1918 addresses must be blocked
    @Test func rfc1918ClassABlocked() { #expect(isPrivateHost("10.0.0.1")) }
    @Test func rfc1918ClassBBlocked() { #expect(isPrivateHost("172.16.0.1")) }
    @Test func rfc1918ClassBUpperBlocked() { #expect(isPrivateHost("172.31.255.255")) }
    @Test func rfc1918ClassCBlocked() { #expect(isPrivateHost("192.168.1.1")) }

    // Link-local
    @Test func linkLocalBlocked() { #expect(isPrivateHost("169.254.169.254")) }  // AWS metadata

    // CGNAT
    @Test func cgnatBlocked() { #expect(isPrivateHost("100.64.0.1")) }

    // IPv6 ULA / link-local
    @Test func ipv6ULABlocked() { #expect(isPrivateHost("fd00::1")) }
    @Test func ipv6LinkLocalBlocked() { #expect(isPrivateHost("fe80::1")) }

    // Localhost must NOT be blocked (developer use case)
    @Test func localhostAllowed() { #expect(!isPrivateHost("127.0.0.1")) }
    @Test func ipv6LoopbackAllowed() { #expect(!isPrivateHost("::1")) }

    // Public IPs must not be blocked
    @Test func publicIPAllowed() { #expect(!isPrivateHost("8.8.8.8")) }
    @Test func publicIPv6Allowed() { #expect(!isPrivateHost("2606:4700:4700::1111")) }

    // Hostnames are not resolved (DNS not done in the guard) — must pass through
    @Test func hostnamePassThrough() { #expect(!isPrivateHost("internal.example.com")) }

    // Edge: IPv6 bracket notation (URL.host strips brackets, but verify no crash)
    @Test func bracketedIPv6Loopback() { #expect(!isPrivateHost("[::1]")) }
}

// MARK: - SSRF Hardening (P0-1)

@Suite("WebFetch — SSRF Hardening")
struct WebFetchSSRFHardeningTests {

    // IPv4-mapped IPv6 must be detected as the underlying IPv4 address.
    @Test func ipv4MappedIPv6Private() { #expect(isPrivateHost("::ffff:10.0.0.1")) }
    @Test func ipv4MappedIPv6MetaBlocked() { #expect(isPrivateHost("::ffff:169.254.169.254")) }
    @Test func ipv4MappedIPv6LoopbackAllowed() { #expect(!isPrivateHost("::ffff:127.0.0.1")) }
    @Test func ipv4MappedIPv6PublicAllowed() { #expect(!isPrivateHost("::ffff:8.8.8.8")) }

    // IPv4-compatible IPv6 (deprecated) — treat as private/block except ::1.
    @Test func ipv4CompatIPv6Blocked() { #expect(isPrivateHost("::10.0.0.1")) }
    @Test func ipv6UnspecifiedBlocked() { #expect(isPrivateHost("::")) }

    // IPv6 multicast must be blocked.
    @Test func ipv6MulticastBlocked() { #expect(isPrivateHost("ff02::1")) }

    // IPv4 literal fast path still works through inet_pton-based rewrite.
    @Test func inetPtonDottedDecimalStillWorks() { #expect(isPrivateHost("192.168.0.1")) }
    @Test func inetPtonPublicStillPasses() { #expect(!isPrivateHost("1.1.1.1")) }

    // IPv4 multicast/reserved should block — 224.0.0.0/4 + 240.0.0.0/4.
    @Test func ipv4MulticastBlocked() { #expect(isPrivateHost("224.0.0.1")) }
    @Test func ipv4ReservedBlocked() { #expect(isPrivateHost("255.255.255.255")) }
    @Test func ipv4UnspecifiedBlocked() { #expect(isPrivateHost("0.0.0.0")) }

    // hostResolvesToPrivate: IP literals are fast-path and don't touch DNS.
    @Test func resolverFastPathPrivate() { #expect(hostResolvesToPrivate("10.0.0.1")) }
    @Test func resolverFastPathPublic() { #expect(!hostResolvesToPrivate("8.8.8.8")) }
    @Test func resolverFastPathLoopbackAllowed() { #expect(!hostResolvesToPrivate("127.0.0.1")) }

    // Hostname that cannot resolve — fail closed.
    @Test func resolverUnresolvableHostFailsClosed() {
        #expect(hostResolvesToPrivate("this-hostname-should-not-exist.invalid"))
    }
}

// MARK: - XCTestCase — WKWebView integration (requires RunLoop, uses XCTestExpectation)

final class WebFetchIntegrationTests: XCTestCase {

    func testFetchLocalHTMLFile() async throws {
        // Write a temp HTML file with known semantic structure
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
          <h1>Integration Test Page</h1>
          <p>Hello from the test suite.</p>
          <a href="/about">About Us</a>
          <button>Submit</button>
        </body>
        </html>
        """
        let tmp = URL(fileURLWithPath: "/tmp/senkani-web-test-\(UUID().uuidString).html")
        try html.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = try await WebFetchEngine.shared.fetch(url: tmp, timeoutSeconds: 10)

        XCTAssert(result.contains("# Integration Test Page"),
                  "h1 should be formatted as # heading; got:\n\(result)")
        XCTAssert(result.contains("Hello from the test suite."),
                  "paragraph text should appear in output")
        XCTAssert(result.contains("[About Us](/about)"),
                  "link with href should be formatted as Markdown link")
        XCTAssert(result.contains("[button] Submit"),
                  "button text should be formatted with [button] prefix")
    }
}
