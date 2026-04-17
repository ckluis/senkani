import Foundation
import WebKit

/// F2 (Schneier re-audit 2026-04-16): block subresource requests to private,
/// link-local, CGNAT, and reserved IPv6 ranges before they leave the machine.
///
/// Why this exists
/// ---------------
/// `WKNavigationDelegate.decidePolicyFor navigationAction:` fires on
/// main-frame navigations and redirects — NOT on subresources (img,
/// script, link, xhr, fetch, etc.). A hostile HTML page returned by
/// `senkani_web` can embed:
///
///     <img src="http://169.254.169.254/latest/meta-data/...">
///     <img src="http://10.0.0.1/admin/users">
///     <script src="http://192.168.1.1/config.js">
///
/// WebKit will dutifully issue those subresource requests during
/// rendering even though the main-frame SSRF guard blocks the initial
/// fetch target. A prompt-injected LLM + hostile-page combination can
/// then scan the internal network or probe cloud metadata.
///
/// `WKContentRuleList` filters at the WebKit network layer and applies
/// to every subresource type. It is pattern-based (no DNS resolution),
/// so hostnames that resolve to private IPs at subresource-request time
/// still reach those IPs — same structural limitation as any hostname
/// blocklist. The main-frame DNS check
/// (`hostResolvesToPrivate` in WebFetchTool) handles that vector for the
/// initial navigation.
///
/// Opt-out
/// -------
/// Setting `SENKANI_WEB_ALLOW_PRIVATE=on` (the same env that bypasses the
/// main-frame SSRF guard) also skips this blocklist. The env is read
/// once at WebFetchEngine warmup — mid-session changes do NOT take
/// effect for the subresource filter, because the rule list must attach
/// to `WKWebViewConfiguration` BEFORE the `WKWebView` is created and the
/// engine caches a single webview.
enum WebContentBlocklist {

    /// Versioned WKContentRuleListStore identifier. Bump when `rulesJSON`
    /// changes so stale compiled lists are replaced on next launch.
    static let identifier = "senkani.web.subresource-blocklist.v1"

    /// WebKit `url-filter` patterns. **WebKit's URL-filter regex is a
    /// restricted subset — notably, the `|` disjunction operator is NOT
    /// supported** (integration test caught this: "Disjunctions are not
    /// supported yet"). Every alternation is split into a separate rule.
    ///
    /// Supported primitives (verified against the macOS WebKit build
    /// used to compile these): `^ $ . * + ? ( )` for grouping, `[…]`
    /// character classes with ranges, and the simple quantifiers.
    ///
    /// Explicitly NOT blocked:
    ///   - 127.0.0.0/8 loopback
    ///   - ::1 IPv6 loopback
    /// (developer use case; also permitted by the main-frame guard).
    ///
    /// `(.*@)?` before the host segment accepts URLs with userinfo —
    /// e.g. `http://user:pass@10.0.0.1/` still matches the 10.x rule.
    ///
    /// `url-filter-is-case-sensitive: false` normalizes host-portion
    /// case so `http://Fe80::1/` and `http://fe80::1/` both match.
    static let rulesJSON: String = """
    [
      {"trigger":{"url-filter":"^https?://(.*@)?10\\\\.","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://(.*@)?172\\\\.1[6-9]\\\\.","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://(.*@)?172\\\\.2[0-9]\\\\.","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://(.*@)?172\\\\.3[01]\\\\.","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://(.*@)?192\\\\.168\\\\.","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://(.*@)?169\\\\.254\\\\.","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://(.*@)?100\\\\.6[4-9]\\\\.","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://(.*@)?100\\\\.[7-9][0-9]\\\\.","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://(.*@)?100\\\\.1[01][0-9]\\\\.","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://(.*@)?100\\\\.12[0-7]\\\\.","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://\\\\[fc","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://\\\\[fd","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://\\\\[fe80","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://\\\\[ff","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://\\\\[::ffff:10\\\\.","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://\\\\[::ffff:169\\\\.254\\\\.","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://\\\\[::ffff:172\\\\.1[6-9]\\\\.","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://\\\\[::ffff:172\\\\.2[0-9]\\\\.","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://\\\\[::ffff:172\\\\.3[01]\\\\.","url-filter-is-case-sensitive":false},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^https?://\\\\[::ffff:192\\\\.168\\\\.","url-filter-is-case-sensitive":false},"action":{"type":"block"}}
    ]
    """

    /// Whether the user has opted out of private-range filtering via env.
    /// Mirrors `WebFetchTool.handle`'s main-frame check.
    static var bypassEnabled: Bool {
        ProcessInfo.processInfo.environment["SENKANI_WEB_ALLOW_PRIVATE"]?.lowercased() == "on"
    }

    /// Compile the rule list via WebKit's on-disk cache. Async because
    /// compilation may do I/O. Returns nil on failure — callers proceed
    /// without the filter and log the error; do NOT crash the tool over
    /// this defense-in-depth layer.
    @MainActor
    static func compile() async -> WKContentRuleList? {
        guard let store = WKContentRuleListStore.default() else {
            FileHandle.standardError.write(
                Data("[MCP] WebContentBlocklist: no default rule-list store available; subresource filter disabled\n".utf8))
            return nil
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<WKContentRuleList?, Never>) in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: rulesJSON
            ) { list, err in
                if let err = err {
                    FileHandle.standardError.write(
                        Data("[MCP] WebContentBlocklist compile failed: \(err.localizedDescription); subresource filter disabled\n".utf8))
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: list)
                }
            }
        }
    }

    // MARK: - Mirror-regex test helper

    /// Test-only helper: parse `rulesJSON` and evaluate each rule's
    /// `url-filter` via `NSRegularExpression` against `url`. Used by
    /// unit tests to verify coverage without requiring WebKit compilation
    /// (which is platform-dependent and async).
    ///
    /// Note: `NSRegularExpression` supports a SUPERSET of WebKit's
    /// URL-filter subset, so this helper is a loose correctness mirror.
    /// The authoritative path is `compile()` returning non-nil in the
    /// integration test.
    static func ruleWouldBlock(_ url: String) -> Bool {
        guard let data = rulesJSON.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return false }

        for rule in arr {
            guard let trigger = rule["trigger"] as? [String: Any],
                  let filter = trigger["url-filter"] as? String,
                  let action = rule["action"] as? [String: Any],
                  (action["type"] as? String) == "block"
            else { continue }

            if let re = try? NSRegularExpression(pattern: filter, options: [.caseInsensitive]) {
                let range = NSRange(url.startIndex..., in: url)
                if re.firstMatch(in: url, range: range) != nil {
                    return true
                }
            }
        }
        return false
    }
}
