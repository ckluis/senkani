import Testing
import Foundation
@testable import Core

/// U.2b-axes contract tests for `SecurityAxis.evaluate`. Pure evaluator
/// over a `SecurityMeasurement` payload. Three assertions:
///
///   - `security.csrf_token_present` (only state-mutating forms count;
///     GET/HEAD excluded).
///   - `security.no_javascript_href` (any `javascript:`-scheme anchor
///     fails the assertion).
///   - `security.script_allowlist` (same-origin OR caller's expected
///     allowlist; everything else fails).
@Suite("SecurityAxis — U.2b-axes evaluator")
struct SecurityAxisTests {

    @Test("CSRF token assertion covers POST-missing-fail, POST-present-pass, GET-excluded-pass, and PUT/PATCH/DELETE-missing-fail")
    func csrfTokenBranches() {
        // Branch 1 — POST form missing CSRF token → fail.
        do {
            let m = SecurityMeasurement(
                forms: [.init(action: "/login", method: "post", csrfTokenPresent: false)],
                anchors: [], scripts: []
            )
            let r = SecurityAxis.evaluate(measurement: m)
            let csrf = r.first { $0.assertionId == "security.csrf_token_present" }
            #expect(csrf?.passed == false)
            #expect(csrf?.measured == 1)
            #expect(csrf?.advisory?.contains("/login") == true)
            #expect(csrf?.advisory?.contains("POST") == true)
        }
        // Branch 2 — POST form with CSRF token → pass; advisory nil.
        do {
            let m = SecurityMeasurement(
                forms: [.init(action: "/login", method: "post", csrfTokenPresent: true)],
                anchors: [], scripts: []
            )
            let r = SecurityAxis.evaluate(measurement: m)
            let csrf = r.first { $0.assertionId == "security.csrf_token_present" }
            #expect(csrf?.passed == true)
            #expect(csrf?.advisory == nil)
        }
        // Branch 3 — GET form is EXCLUDED from the assertion entirely
        // (GETs shouldn't have side effects → no CSRF requirement).
        do {
            let m = SecurityMeasurement(
                forms: [.init(action: "/search", method: "get", csrfTokenPresent: false)],
                anchors: [], scripts: []
            )
            let r = SecurityAxis.evaluate(measurement: m)
            let csrf = r.first { $0.assertionId == "security.csrf_token_present" }
            #expect(csrf?.passed == true)
            #expect(csrf?.measured == 0, "GET forms must not count toward mutating-form total")
        }
        // Branch 4 — PUT / PATCH / DELETE missing CSRF token → fail.
        do {
            let m = SecurityMeasurement(
                forms: [
                    .init(action: "/users/1", method: "put", csrfTokenPresent: false),
                    .init(action: "/users/1", method: "delete", csrfTokenPresent: false),
                    .init(action: "/users/1", method: "patch", csrfTokenPresent: true),
                ],
                anchors: [], scripts: []
            )
            let r = SecurityAxis.evaluate(measurement: m)
            let csrf = r.first { $0.assertionId == "security.csrf_token_present" }
            #expect(csrf?.passed == false)
            #expect(csrf?.measured == 3)
            // Advisory lists 2 failing forms (PUT + DELETE; PATCH passes)
            #expect(csrf?.advisory?.contains("2 state-mutating form(s)") == true)
        }
    }

    @Test("javascript: href assertion fails on any matching anchor; case-insensitive")
    func noJavascriptHrefBranches() {
        // Branch 1 — anchors with `javascript:` (and `JavaScript:`) hrefs.
        do {
            let m = SecurityMeasurement(
                forms: [],
                anchors: [
                    .init(href: "https://example.com/safe"),
                    .init(href: "javascript:alert(1)"),
                    .init(href: "JavaScript:void(0)"),
                ],
                scripts: []
            )
            let r = SecurityAxis.evaluate(measurement: m)
            let a = r.first { $0.assertionId == "security.no_javascript_href" }
            #expect(a?.passed == false)
            #expect(a?.measured == 3)
            #expect(a?.advisory?.contains("javascript:alert(1)") == true)
            #expect(a?.advisory?.contains("JavaScript:void(0)") == true)
        }
        // Branch 2 — all anchors safe → pass.
        do {
            let m = SecurityMeasurement(
                forms: [],
                anchors: [
                    .init(href: "https://example.com/safe"),
                    .init(href: "/relative/path"),
                    .init(href: "mailto:user@example.com"),
                ],
                scripts: []
            )
            let r = SecurityAxis.evaluate(measurement: m)
            let a = r.first { $0.assertionId == "security.no_javascript_href" }
            #expect(a?.passed == true)
            #expect(a?.advisory == nil)
        }
    }

    @Test("script allowlist passes same-origin + listed; fails off-allowlist; expected.script_allowlist threads through")
    func scriptAllowlistBranches() {
        // Branch 1 — same-origin script → pass.
        do {
            let m = SecurityMeasurement(
                forms: [], anchors: [],
                scripts: [.init(src: "/static/app.js", sameOrigin: true)]
            )
            let r = SecurityAxis.evaluate(measurement: m)
            let s = r.first { $0.assertionId == "security.script_allowlist" }
            #expect(s?.passed == true)
            #expect(s?.advisory == nil)
        }
        // Branch 2 — off-origin script not in allowlist → fail.
        do {
            let m = SecurityMeasurement(
                forms: [], anchors: [],
                scripts: [.init(src: "https://evil.cdn/inject.js", sameOrigin: false)]
            )
            let r = SecurityAxis.evaluate(measurement: m)
            let s = r.first { $0.assertionId == "security.script_allowlist" }
            #expect(s?.passed == false)
            #expect(s?.advisory?.contains("https://evil.cdn/inject.js") == true)
        }
        // Branch 3 — off-origin script in caller's allowlist → pass.
        do {
            let m = SecurityMeasurement(
                forms: [], anchors: [],
                scripts: [.init(src: "https://cdn.jsdelivr.net/lib.js", sameOrigin: false)]
            )
            let e = SecurityExpected(scriptAllowlist: ["https://cdn.jsdelivr.net/lib.js"])
            let r = SecurityAxis.evaluate(measurement: m, expected: e)
            let s = r.first { $0.assertionId == "security.script_allowlist" }
            #expect(s?.passed == true)
            #expect(s?.advisory == nil)
        }
        // Branch 4 — mixed: same-origin pass, allowlisted pass, off-allowlist fail.
        do {
            let m = SecurityMeasurement(
                forms: [], anchors: [],
                scripts: [
                    .init(src: "/static/a.js", sameOrigin: true),
                    .init(src: "https://allowed.cdn/b.js", sameOrigin: false),
                    .init(src: "https://blocked.cdn/c.js", sameOrigin: false),
                ]
            )
            let e = SecurityExpected(scriptAllowlist: ["https://allowed.cdn/b.js"])
            let r = SecurityAxis.evaluate(measurement: m, expected: e)
            let s = r.first { $0.assertionId == "security.script_allowlist" }
            #expect(s?.passed == false)
            #expect(s?.measured == 3)
            #expect(s?.advisory?.contains("blocked.cdn/c.js") == true)
            #expect(s?.advisory?.contains("allowed.cdn/b.js") == false,
                    "allowlisted off-origin script must NOT appear in the failure advisory")
        }
    }
}
