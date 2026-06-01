import Testing
import Foundation
@testable import Core

/// T.1d.3 — request-dimension matchers for the egress rule engine.
///
/// Covers the body-substring / header / path match dimensions added to
/// `EgressRule`, the `EgressRequest` parsed-request type, and the new
/// `EgressRuleEngine.evaluate(request:)` deny-wins loop. Also pins the
/// backward-compat guarantee that `evaluate(host:)` stays byte-identical:
/// a rule carrying any body/header/path dimension is INERT under a
/// host-only evaluation.
@Suite("EgressProxy — request-dimension matchers (T.1d.3)")
struct EgressRuleEngineRequestMatchersTests {

    // MARK: - Body substring

    @Test("Body-substring DENY overrides a host allow (deny-wins)")
    func bodyDenyOverridesHostAllow() {
        let allow = EgressRule(
            id: "allow-host",
            pattern: "api.example.com",
            mode: .suffix,
            decision: .allow
        )
        let bodyDeny = EgressRule(
            id: "deny-secret-body",
            pattern: "api.example.com",
            mode: .suffix,
            decision: .deny,
            bodyContains: "ssh-rsa",
            header: nil,
            path: nil
        )
        let engine = EgressRuleEngine(rules: [allow, bodyDeny])

        // Body carries the deny substring ⇒ deny-wins even though the host
        // is allowlisted.
        let withSecret = EgressRequest(
            host: "api.example.com",
            method: "POST",
            path: "/upload",
            headers: [],
            bodyExcerpt: "key=ssh-rsa AAAAB3Nza..."
        )
        let denied = engine.evaluate(request: withSecret)
        #expect(denied.decision == .deny)
        #expect(denied.ruleId == "deny-secret-body")

        // Same host, no secret in the body ⇒ host allow wins.
        let clean = EgressRequest(
            host: "api.example.com",
            method: "POST",
            path: "/upload",
            headers: [],
            bodyExcerpt: "key=hello"
        )
        let allowed = engine.evaluate(request: clean)
        #expect(allowed.decision == .allow)
        #expect(allowed.ruleId == "allow-host")
    }

    @Test("Body rule with nil bodyExcerpt does NOT match (fail-closed on the rule, fail-open overall)")
    func bodyRuleRequiresExcerpt() {
        let bodyDeny = EgressRule(
            id: "deny-body",
            pattern: "api.example.com",
            mode: .suffix,
            decision: .deny,
            bodyContains: "secret",
            header: nil,
            path: nil
        )
        let rule = bodyDeny
        // No excerpt supplied ⇒ the body dimension cannot be satisfied ⇒ no match.
        let noBody = EgressRequest(host: "api.example.com", bodyExcerpt: nil)
        #expect(!rule.matches(request: noBody))
        // Body present but substring absent ⇒ no match.
        let other = EgressRequest(host: "api.example.com", bodyExcerpt: "nothing here")
        #expect(!rule.matches(request: other))
    }

    @Test("Body substring is case-SENSITIVE (documented evasion)")
    func bodyMatchIsCaseSensitive() {
        let rule = EgressRule(
            id: "deny-body",
            pattern: "api.example.com",
            mode: .suffix,
            decision: .deny,
            bodyContains: "SECRET",
            header: nil,
            path: nil
        )
        #expect(rule.matches(request: EgressRequest(host: "api.example.com", bodyExcerpt: "a SECRET b")))
        // Lowercase variant evades — best-effort, documented fail-open.
        #expect(!rule.matches(request: EgressRequest(host: "api.example.com", bodyExcerpt: "a secret b")))
    }

    // MARK: - Header

    @Test("Header NAME match is case-insensitive (authorization matches Authorization)")
    func headerNameCaseInsensitive() {
        let rule = EgressRule(
            id: "deny-auth",
            pattern: "api.example.com",
            mode: .suffix,
            decision: .deny,
            bodyContains: nil,
            header: EgressRule.HeaderMatch(name: "authorization", valueContains: nil),
            path: nil
        )
        let req = EgressRequest(
            host: "api.example.com",
            headers: [("Authorization", "Bearer xyz")]
        )
        #expect(rule.matches(request: req))

        // Mixed-case rule name + lowercase request header also matches.
        let rule2 = EgressRule(
            id: "deny-auth2",
            pattern: "api.example.com",
            mode: .suffix,
            decision: .deny,
            bodyContains: nil,
            header: EgressRule.HeaderMatch(name: "AUTHORIZATION", valueContains: nil),
            path: nil
        )
        let req2 = EgressRequest(
            host: "api.example.com",
            headers: [("authorization", "Bearer xyz")]
        )
        #expect(rule2.matches(request: req2))

        // Absent header ⇒ no match.
        let noHeader = EgressRequest(host: "api.example.com", headers: [("Accept", "*/*")])
        #expect(!rule.matches(request: noHeader))
    }

    @Test("Header value substring is case-sensitive and OWS-trimmed")
    func headerValueContainsTrimsOWS() {
        let rule = EgressRule(
            id: "deny-bearer",
            pattern: "api.example.com",
            mode: .suffix,
            decision: .deny,
            bodyContains: nil,
            header: EgressRule.HeaderMatch(name: "authorization", valueContains: "Bearer"),
            path: nil
        )
        // Value carries leading/trailing OWS (spaces + tabs) around "Bearer ...".
        let req = EgressRequest(
            host: "api.example.com",
            headers: [("Authorization", " \tBearer secret\t ")]
        )
        #expect(rule.matches(request: req))

        // Value present but substring (case-sensitive) absent.
        let lower = EgressRequest(
            host: "api.example.com",
            headers: [("Authorization", "bearer secret")]
        )
        #expect(!rule.matches(request: lower))
    }

    @Test("Header match scans ALL duplicate-named headers")
    func headerMatchScansDuplicates() {
        let rule = EgressRule(
            id: "deny-fwd",
            pattern: "api.example.com",
            mode: .suffix,
            decision: .deny,
            bodyContains: nil,
            header: EgressRule.HeaderMatch(name: "x-forwarded-for", valueContains: "10.0.0.1"),
            path: nil
        )
        let req = EgressRequest(
            host: "api.example.com",
            headers: [
                ("X-Forwarded-For", "8.8.8.8"),
                ("X-Forwarded-For", "10.0.0.1")
            ]
        )
        #expect(rule.matches(request: req))
    }

    // MARK: - Path + normalization bypass

    @Test("Path DENY catches normalization-bypass variants of /admin")
    func pathDenyCatchesNormalizationBypasses() {
        let rule = EgressRule(
            id: "deny-admin",
            pattern: "api.example.com",
            mode: .suffix,
            decision: .deny,
            bodyContains: nil,
            header: nil,
            path: EgressRule.PathMatch(value: "/admin", mode: .exact)
        )
        // Direct hit + each documented bypass must still be caught.
        let bypasses = [
            "/admin",
            "/./admin",
            "/a/../admin",
            "//admin",
            "%61dmin",       // percent-encoded leading 'a'
            "/%61dmin",
            "/admin/",       // trailing slash dropped
            "/admin?x=1",    // query stripped
            "/./a/../admin/"
        ]
        for p in bypasses {
            let req = EgressRequest(host: "api.example.com", path: p)
            #expect(rule.matches(request: req), "expected /admin deny to catch path \(p)")
        }

        // A genuinely different path is NOT caught.
        let other = EgressRequest(host: "api.example.com", path: "/administrator")
        #expect(!rule.matches(request: other))
        // Nil path ⇒ path dimension unsatisfiable ⇒ no match.
        let noPath = EgressRequest(host: "api.example.com", path: nil)
        #expect(!rule.matches(request: noPath))
    }

    @Test("normalizePath canonicalization matrix")
    func normalizePathMatrix() {
        #expect(EgressRule.normalizePath("/admin") == "/admin")
        #expect(EgressRule.normalizePath("/admin/") == "/admin")
        #expect(EgressRule.normalizePath("//admin") == "/admin")
        #expect(EgressRule.normalizePath("/./admin") == "/admin")
        #expect(EgressRule.normalizePath("/a/../admin") == "/admin")
        #expect(EgressRule.normalizePath("%61dmin") == "/admin")
        #expect(EgressRule.normalizePath("/admin?q=1") == "/admin")
        #expect(EgressRule.normalizePath("/admin#frag") == "/admin")
        #expect(EgressRule.normalizePath("/") == "/")
        #expect(EgressRule.normalizePath("") == "/")
        #expect(EgressRule.normalizePath("/../../etc/passwd") == "/etc/passwd") // .. never escapes root
        #expect(EgressRule.normalizePath("/a//b///c") == "/a/b/c")
        // Case-sensitive: /Admin is distinct from /admin.
        #expect(EgressRule.normalizePath("/Admin") == "/Admin")
    }

    @Test("Path prefix + contains modes")
    func pathPrefixAndContainsModes() {
        let prefixRule = EgressRule(
            id: "deny-api-prefix",
            pattern: "api.example.com",
            mode: .suffix,
            decision: .deny,
            bodyContains: nil,
            header: nil,
            path: EgressRule.PathMatch(value: "/internal", mode: .prefix)
        )
        #expect(prefixRule.matches(request: EgressRequest(host: "api.example.com", path: "/internal/metrics")))
        #expect(!prefixRule.matches(request: EgressRequest(host: "api.example.com", path: "/public")))

        let containsRule = EgressRule(
            id: "deny-contains",
            pattern: "api.example.com",
            mode: .suffix,
            decision: .deny,
            bodyContains: nil,
            header: nil,
            path: EgressRule.PathMatch(value: "secret", mode: .contains)
        )
        #expect(containsRule.matches(request: EgressRequest(host: "api.example.com", path: "/a/secret/b")))
        #expect(!containsRule.matches(request: EgressRequest(host: "api.example.com", path: "/a/b")))
    }

    // MARK: - AND-within-rule

    @Test("Over-specified rule matches only when EVERY dimension matches (AND-within-rule)")
    func andWithinRule() {
        let rule = EgressRule(
            id: "deny-all-dims",
            pattern: "api.example.com",
            mode: .suffix,
            decision: .deny,
            bodyContains: "token",
            header: EgressRule.HeaderMatch(name: "x-flag", valueContains: "on"),
            path: EgressRule.PathMatch(value: "/admin", mode: .exact)
        )
        // All four dimensions satisfied ⇒ match.
        let full = EgressRequest(
            host: "api.example.com",
            path: "/admin",
            headers: [("X-Flag", "on")],
            bodyExcerpt: "has token here"
        )
        #expect(rule.matches(request: full))

        // Drop the header ⇒ no match (one missing conjunct kills it).
        let noHeader = EgressRequest(
            host: "api.example.com",
            path: "/admin",
            headers: [],
            bodyExcerpt: "has token here"
        )
        #expect(!rule.matches(request: noHeader))

        // Wrong host ⇒ no match even with body/header/path satisfied.
        let wrongHost = EgressRequest(
            host: "evil.test",
            path: "/admin",
            headers: [("X-Flag", "on")],
            bodyExcerpt: "has token here"
        )
        #expect(!rule.matches(request: wrongHost))
    }

    // MARK: - Engine deny-wins over a separate host-allow rule

    @Test("Header/path deny overrides a SEPARATE host-allow rule via evaluate(request:)")
    func denyWinsAcrossSeparateRules() {
        let hostAllow = EgressRule(
            id: "allow-host",
            pattern: "example.com",
            mode: .suffix,
            decision: .allow
        )
        let headerDeny = EgressRule(
            id: "deny-auth-header",
            pattern: "example.com",
            mode: .suffix,
            decision: .deny,
            bodyContains: nil,
            header: EgressRule.HeaderMatch(name: "authorization", valueContains: nil),
            path: nil
        )
        let pathDeny = EgressRule(
            id: "deny-admin-path",
            pattern: "example.com",
            mode: .suffix,
            decision: .deny,
            bodyContains: nil,
            header: nil,
            path: EgressRule.PathMatch(value: "/admin", mode: .exact)
        )
        // Order: allow first, then the deny rules. Deny must still win.
        let engine = EgressRuleEngine(rules: [hostAllow, headerDeny, pathDeny])

        // Carries an Authorization header ⇒ header deny wins.
        let withAuth = EgressRequest(
            host: "api.example.com",
            path: "/ok",
            headers: [("Authorization", "Bearer x")]
        )
        let r1 = engine.evaluate(request: withAuth)
        #expect(r1.decision == .deny)
        #expect(r1.ruleId == "deny-auth-header")

        // Hits /admin (via a bypass form) ⇒ path deny wins.
        let withAdmin = EgressRequest(
            host: "api.example.com",
            path: "/a/../admin",
            headers: []
        )
        let r2 = engine.evaluate(request: withAdmin)
        #expect(r2.decision == .deny)
        #expect(r2.ruleId == "deny-admin-path")

        // Neither deny condition present ⇒ host allow wins.
        let plain = EgressRequest(host: "api.example.com", path: "/ok", headers: [])
        let r3 = engine.evaluate(request: plain)
        #expect(r3.decision == .allow)
        #expect(r3.ruleId == "allow-host")
    }

    // MARK: - Backward-compat parity (the critical guarantee)

    @Test("evaluate(host:) is byte-identical: body/header/path rules are INERT")
    func evaluateHostBackwardCompatParity() {
        // Full rule set: a host allow + a host deny + three request-only
        // deny rules (body/header/path) that must be INERT under host-only.
        let hostAllow = EgressRule(id: "allow-host", pattern: "example.com", mode: .suffix, decision: .allow)
        let hostDeny  = EgressRule(id: "deny-evil", pattern: "evil.example.com", mode: .exact, decision: .deny)
        let bodyDeny  = EgressRule(
            id: "deny-body", pattern: "example.com", mode: .suffix, decision: .deny,
            bodyContains: "secret", header: nil, path: nil
        )
        let headerDeny = EgressRule(
            id: "deny-header", pattern: "example.com", mode: .suffix, decision: .deny,
            bodyContains: nil, header: EgressRule.HeaderMatch(name: "authorization", valueContains: nil), path: nil
        )
        let pathDeny = EgressRule(
            id: "deny-path", pattern: "example.com", mode: .suffix, decision: .deny,
            bodyContains: nil, header: nil, path: EgressRule.PathMatch(value: "/admin", mode: .exact)
        )

        let fullEngine = EgressRuleEngine(rules: [hostAllow, hostDeny, bodyDeny, headerDeny, pathDeny])
        // Host-only subset = exactly the two host rules (the inert ones removed).
        let subsetEngine = EgressRuleEngine(rules: [hostAllow, hostDeny])

        let hosts = [
            "api.example.com",
            "example.com",
            "evil.example.com",
            "Example.COM:80",
            "unknown.host",
            "deep.api.example.com"
        ]
        for h in hosts {
            let full = fullEngine.evaluate(host: h)
            let subset = subsetEngine.evaluate(host: h)
            #expect(full.decision == subset.decision, "decision mismatch for host \(h)")
            #expect(full.ruleId == subset.ruleId, "ruleId mismatch for host \(h)")
        }

        // Specifically: the body deny rule MUST NOT fire under host-only,
        // so an allowlisted host that WOULD trip the body deny in
        // evaluate(request:) is still ALLOWED under evaluate(host:).
        let hostResult = fullEngine.evaluate(host: "api.example.com")
        #expect(hostResult.decision == .allow)
        #expect(hostResult.ruleId == "allow-host")
    }

    @Test("matches(host:) returns false for any rule carrying a request dimension")
    func matchesHostFalseForRequestDimensionRules() {
        let bodyRule = EgressRule(
            id: "b", pattern: "example.com", mode: .suffix, decision: .deny,
            bodyContains: "x", header: nil, path: nil
        )
        let headerRule = EgressRule(
            id: "h", pattern: "example.com", mode: .suffix, decision: .deny,
            bodyContains: nil, header: EgressRule.HeaderMatch(name: "a"), path: nil
        )
        let pathRule = EgressRule(
            id: "p", pattern: "example.com", mode: .suffix, decision: .deny,
            bodyContains: nil, header: nil, path: EgressRule.PathMatch(value: "/x", mode: .exact)
        )
        // Host that WOULD match the host pattern, but rule carries a
        // request dimension ⇒ matches(host:) is false.
        #expect(!bodyRule.matches(host: "api.example.com"))
        #expect(!headerRule.matches(host: "api.example.com"))
        #expect(!pathRule.matches(host: "api.example.com"))
        #expect(bodyRule.hasRequestDimension)
        #expect(headerRule.hasRequestDimension)
        #expect(pathRule.hasRequestDimension)

        // A plain host rule is unaffected.
        let hostRule = EgressRule(id: "host", pattern: "example.com", mode: .suffix, decision: .allow)
        #expect(hostRule.matches(host: "api.example.com"))
        #expect(!hostRule.hasRequestDimension)
    }

    // MARK: - Host-only rules still work via evaluate(request:)

    @Test("Host-only rules participate normally in evaluate(request:)")
    func hostOnlyRulesViaEvaluateRequest() {
        let engine = EgressRuleEngine(rules: [
            EgressRule(id: "allow", pattern: "example.com", mode: .suffix, decision: .allow)
        ])
        let allowed = engine.evaluate(request: EgressRequest(host: "Api.Example.COM:443", path: "/x"))
        #expect(allowed.decision == .allow)
        #expect(allowed.ruleId == "allow")

        let missed = engine.evaluate(request: EgressRequest(host: "other.test", path: "/x"))
        #expect(missed.decision == .deny)
        #expect(missed.ruleId == "default-deny")
    }

    // MARK: - EgressRequest Equatable

    @Test("EgressRequest Equatable compares headers element-wise")
    func egressRequestEquatable() {
        let a = EgressRequest(host: "h", headers: [("A", "1"), ("B", "2")])
        let b = EgressRequest(host: "h", headers: [("A", "1"), ("B", "2")])
        let c = EgressRequest(host: "h", headers: [("A", "1"), ("B", "3")])
        let d = EgressRequest(host: "h", headers: [("A", "1")])
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }
}
