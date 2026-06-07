import Foundation

/// Browser-measured security payload. The TS runner walks the DOM in
/// `page.evaluate(...)` and emits this shape; the Swift evaluator
/// consumes it. U.2b-axes ships the Swift evaluator + measurement
/// types; full TS-side DOM walks for the three assertions are tracked
/// under the mandatory-follow-up item filed at U.2b-axes close (the
/// runner's stub branch passes empty measurements through to the
/// evaluator until then).
public struct SecurityMeasurement: Codable, Sendable, Equatable {
    public let forms: [FormElement]
    public let anchors: [AnchorElement]
    public let scripts: [ScriptElement]

    public init(
        forms: [FormElement] = [],
        anchors: [AnchorElement] = [],
        scripts: [ScriptElement] = []
    ) {
        self.forms = forms
        self.anchors = anchors
        self.scripts = scripts
    }

    /// One `<form>` element. `method` is the form's HTTP method (case-
    /// folded to lowercase at parse time). `csrfTokenPresent` is true
    /// when ANY child `<input>` carries a name matching the
    /// `SecurityAxis.csrfTokenNamePatterns` set.
    public struct FormElement: Codable, Sendable, Equatable {
        public let action: String?
        public let method: String
        public let csrfTokenPresent: Bool

        public init(action: String? = nil, method: String, csrfTokenPresent: Bool) {
            self.action = action
            self.method = method
            self.csrfTokenPresent = csrfTokenPresent
        }

        enum CodingKeys: String, CodingKey {
            case action
            case method
            case csrfTokenPresent = "csrf_token_present"
        }
    }

    /// One `<a>` element. `href` is the raw href attribute string;
    /// the evaluator string-matches the `javascript:` scheme prefix.
    public struct AnchorElement: Codable, Sendable, Equatable {
        public let href: String

        public init(href: String) {
            self.href = href
        }
    }

    /// One `<script>` element with an external `src`. Inline scripts
    /// (no `src` attribute) are out of scope for this assertion — the
    /// evaluator only sees externally-sourced scripts.
    public struct ScriptElement: Codable, Sendable, Equatable {
        public let src: String
        public let sameOrigin: Bool

        public init(src: String, sameOrigin: Bool) {
            self.src = src
            self.sameOrigin = sameOrigin
        }

        enum CodingKeys: String, CodingKey {
            case src
            case sameOrigin = "same_origin"
        }
    }
}

/// Caller-supplied overrides for security assertions. Decoded from
/// `ValidationStep.expected` (TEXT, JSON) when present.
public struct SecurityExpected: Codable, Sendable, Equatable {
    /// Additional script `src` URLs (or host suffixes — exact-match
    /// against the script's full src string) the caller declares safe.
    /// The evaluator allows a script when it is same-origin OR appears
    /// in this list.
    public let scriptAllowlist: [String]?

    public init(scriptAllowlist: [String]? = nil) {
        self.scriptAllowlist = scriptAllowlist
    }

    enum CodingKeys: String, CodingKey {
        case scriptAllowlist = "script_allowlist"
    }
}

/// Security axis evaluator. Pure function over a `SecurityMeasurement`
/// payload. Returns three `AssertionResult` rows:
///
///   - `security.csrf_token_present` — every `<form method="post">`
///     (or PUT/PATCH/DELETE) carries a child `<input>` whose name
///     matches one of `csrfTokenNamePatterns`. Forms whose method is
///     GET or HEAD are excluded.
///   - `security.no_javascript_href` — no `<a href="javascript:...">`
///     in the rendered DOM (XSS-by-link surface).
///   - `security.script_allowlist` — every external `<script src>` is
///     same-origin OR appears in the caller's `script_allowlist`.
///
/// **Schneier audit (round-time):** the assertion advisories report the
/// failing element's URL or method but never the page's raw HTML or
/// the script body — same side-channel guard the U.2a-2b HookRouter
/// refusal envelope ships. Element identifiers are sufficient for
/// remediation; full payload exfiltration is gratuitous.
public enum SecurityAxis {
    /// Case-insensitive substrings the evaluator looks for in form
    /// child `<input name>` attributes when deciding whether a form
    /// carries a CSRF token. The TS-side measurement collapses the
    /// boolean into `FormElement.csrfTokenPresent` so the Swift
    /// evaluator stays consumer-side simple; the patterns ship here
    /// for documentation + parity with the TS implementation.
    public static let csrfTokenNamePatterns: [String] = [
        "csrf", "_token", "authenticity_token", "anti_xsrf",
    ]

    /// HTTP methods that MUST carry a CSRF token. GET / HEAD / OPTIONS
    /// excluded (they shouldn't have side effects per spec).
    public static let methodsRequiringCSRFToken: Set<String> = [
        "post", "put", "patch", "delete",
    ]

    public static func evaluate(
        measurement: SecurityMeasurement,
        expected: SecurityExpected? = nil
    ) -> [AssertionResult] {
        var results: [AssertionResult] = []

        // 1) CSRF token presence on state-mutating forms
        let mutatingForms = measurement.forms.filter { f in
            methodsRequiringCSRFToken.contains(f.method.lowercased())
        }
        let csrfMissing = mutatingForms.filter { !$0.csrfTokenPresent }
        let csrfPass = csrfMissing.isEmpty
        let csrfAdvisory: String?
        if csrfPass {
            csrfAdvisory = nil
        } else {
            let preview = csrfMissing.prefix(5).map { f in
                "\(f.method.uppercased()) \(f.action ?? "<no action>")"
            }.joined(separator: ", ")
            csrfAdvisory = "\(csrfMissing.count) state-mutating form(s) missing CSRF token: \(preview)"
        }
        results.append(AssertionResult(
            assertionId: "security.csrf_token_present",
            passed: csrfPass,
            measured: mutatingForms.count,
            threshold: nil,
            advisory: csrfAdvisory
        ))

        // 2) No javascript: href in the rendered DOM
        let jsHrefAnchors = measurement.anchors.filter { a in
            a.href.lowercased().hasPrefix("javascript:")
        }
        let jsHrefPass = jsHrefAnchors.isEmpty
        let jsHrefAdvisory: String?
        if jsHrefPass {
            jsHrefAdvisory = nil
        } else {
            let preview = jsHrefAnchors.prefix(5).map(\.href).joined(separator: ", ")
            jsHrefAdvisory = "\(jsHrefAnchors.count) anchor(s) use the javascript: scheme: \(preview)"
        }
        results.append(AssertionResult(
            assertionId: "security.no_javascript_href",
            passed: jsHrefPass,
            measured: measurement.anchors.count,
            threshold: nil,
            advisory: jsHrefAdvisory
        ))

        // 3) Script allowlist — same-origin OR in caller's list
        let allowlist = Set(expected?.scriptAllowlist ?? [])
        let offAllowlistScripts = measurement.scripts.filter { s in
            if s.sameOrigin { return false }
            if allowlist.contains(s.src) { return false }
            return true
        }
        let allowlistPass = offAllowlistScripts.isEmpty
        let allowlistAdvisory: String?
        if allowlistPass {
            allowlistAdvisory = nil
        } else {
            let preview = offAllowlistScripts.prefix(5).map(\.src).joined(separator: ", ")
            allowlistAdvisory = "\(offAllowlistScripts.count) external script src(s) off-allowlist (not same-origin, not in expected.script_allowlist): \(preview)"
        }
        results.append(AssertionResult(
            assertionId: "security.script_allowlist",
            passed: allowlistPass,
            measured: measurement.scripts.count,
            threshold: nil,
            advisory: allowlistAdvisory
        ))

        return results
    }
}
