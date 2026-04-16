import Testing
import Foundation
@testable import MCPServer

/// Bach G4: extracted RedirectPolicy.decide from NavigationHandler so the
/// SSRF defense-in-depth redirect logic can be tested without WKWebView /
/// WKNavigationAction mocking.
@Suite("RedirectPolicy")
struct RedirectPolicyTests {

    // MARK: - Initial navigation: any scheme allowed

    @Test func initialNavigationAllowsAnyScheme() {
        for scheme in ["http", "https", "file", "data"] {
            let url = URL(string: "\(scheme)://example.com/")!
            #expect(
                RedirectPolicy.decide(url: url, navigationIndex: 1, allowPrivate: false)
                    == .allow,
                "initial nav with \(scheme):// must be allowed (handle() already vetted the real-request scheme)"
            )
        }
    }

    // MARK: - Redirect: scheme allowlist

    @Test func redirectToFileSchemeRejected() {
        let url = URL(string: "file:///etc/passwd")!
        #expect(
            RedirectPolicy.decide(url: url, navigationIndex: 2, allowPrivate: false)
                == .cancel(.invalidURL)
        )
    }

    @Test func redirectToDataSchemeRejected() {
        let url = URL(string: "data:text/html,<script>alert(1)</script>")!
        #expect(
            RedirectPolicy.decide(url: url, navigationIndex: 2, allowPrivate: false)
                == .cancel(.invalidURL)
        )
    }

    @Test func redirectToJavascriptSchemeRejected() {
        let url = URL(string: "javascript:alert(1)")!
        #expect(
            RedirectPolicy.decide(url: url, navigationIndex: 2, allowPrivate: false)
                == .cancel(.invalidURL)
        )
    }

    @Test func redirectToHttpAllowed() {
        let url = URL(string: "http://example.com/")!
        #expect(
            RedirectPolicy.decide(url: url, navigationIndex: 2, allowPrivate: false)
                == .allow
        )
    }

    @Test func redirectToHttpsAllowed() {
        let url = URL(string: "https://example.com/")!
        #expect(
            RedirectPolicy.decide(url: url, navigationIndex: 2, allowPrivate: false)
                == .allow
        )
    }

    // MARK: - Redirect: private IP rejection

    @Test func redirectToPrivateIPv4Rejected() {
        let url = URL(string: "http://10.0.0.1/admin")!
        #expect(
            RedirectPolicy.decide(url: url, navigationIndex: 2, allowPrivate: false)
                == .cancel(.privateAddressBlocked)
        )
    }

    @Test func redirectToCloudMetadataRejected() {
        let url = URL(string: "http://169.254.169.254/latest/meta-data/")!
        #expect(
            RedirectPolicy.decide(url: url, navigationIndex: 2, allowPrivate: false)
                == .cancel(.privateAddressBlocked)
        )
    }

    @Test func redirectToIPv4MappedIPv6PrivateRejected() {
        let url = URL(string: "http://[::ffff:10.0.0.1]/")!
        #expect(
            RedirectPolicy.decide(url: url, navigationIndex: 2, allowPrivate: false)
                == .cancel(.privateAddressBlocked)
        )
    }

    @Test func redirectToPrivateIPAllowedWhenAllowPrivateTrue() {
        let url = URL(string: "http://10.0.0.1/admin")!
        #expect(
            RedirectPolicy.decide(url: url, navigationIndex: 2, allowPrivate: true)
                == .allow,
            "SENKANI_WEB_ALLOW_PRIVATE=on must allow redirect to private"
        )
    }

    // MARK: - Depth cap

    @Test func sixthNavigationRejected() {
        // Initial nav = index 1; redirects 2..6 allowed; index 7 blocked.
        let url = URL(string: "https://example.com/")!
        #expect(
            RedirectPolicy.decide(url: url, navigationIndex: 6, allowPrivate: false)
                == .allow,
            "5 redirects after initial = index 6, still allowed"
        )
        #expect(
            RedirectPolicy.decide(url: url, navigationIndex: 7, allowPrivate: false)
                == .cancel(.tooManyRedirects)
        )
    }

    // MARK: - Nil URL

    @Test func nilURLRejected() {
        #expect(
            RedirectPolicy.decide(url: nil, navigationIndex: 1, allowPrivate: false)
                == .cancel(.invalidURL)
        )
    }
}
