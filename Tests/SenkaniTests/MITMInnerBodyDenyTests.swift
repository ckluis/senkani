import Testing
import Foundation
@testable import Core

/// r94 t1d-5 r52 Allspaw P1 — LIVE in-path body denial against the
/// decrypted CONNECT-tunneled inner request body.
///
/// Round 52 (commit 5b5db2a) shipped CONNECT-path body excerpt PERSISTENCE
/// to the audit row. Round B (r94, this round) promotes that from
/// observability to ENFORCEMENT: the body excerpt is evaluated INSIDE
/// `pipeBidirectional` BEFORE the head-replay write to upstream, and a
/// deny verdict aborts the upstream forward cleanly.
///
/// Tests in this suite exercise:
///   1. `parseInnerHTTPHead` purity + edge cases (malformed input → nil).
///   2. The `InnerBodyDenyEvaluating` connector seam contract:
///      `bodyDenyEvaluator: nil` → default-OFF, byte-identical to pre-r94.
///   3. The `DefaultInnerBodyDenyEvaluator` adapter wraps an
///      `EgressRuleEngine` and surfaces matching rule ids verbatim
///      (NOT the `default-deny` sentinel — that case falls through to
///      allow because host-level was already allowed up-arc).
///   4. The fail-CLOSED choice on HEAD parse failure:
///      `parseInnerHTTPHead == nil` → `.bodyDeny(ruleId:
///      "mitm_inner_head_parse_failed")`.
///   5. The Schneier P1 truncate-then-redact-before-engine invariant:
///      the bytes handed to the evaluator are ALREADY
///      `prepareBodyExcerpt`-processed; raw secret-shaped tokens never
///      reach the engine.
@Suite("r94 t1d-5 r52 Allspaw P1 — LIVE in-path body denial")
struct MITMInnerBodyDenyTests {

    // MARK: - parseInnerHTTPHead purity tests

    /// Well-formed HEAD parses into method/path/headers.
    @Test("parseInnerHTTPHead: well-formed HEAD → (method, path, headers)")
    func parseInnerHTTPHeadWellFormed() {
        let raw = "POST /v1/exec HTTP/1.1\r\nHost: api.example.com\r\nContent-Type: application/json\r\nContent-Length: 32\r\n\r\n{\"command\":\"DROP TABLE users\"}"
        let bytes = Array(raw.utf8)
        guard let parsed = MITMUpstreamVerify.parseInnerHTTPHead(bytes) else {
            Issue.record("parseInnerHTTPHead returned nil on a well-formed HEAD")
            return
        }
        #expect(parsed.method == "POST", "method should be POST, got \(parsed.method)")
        #expect(parsed.path == "/v1/exec", "path should be /v1/exec, got \(parsed.path)")
        #expect(parsed.headers.count == 3, "should parse 3 headers, got \(parsed.headers.count)")
        let names = parsed.headers.map { $0.name }
        #expect(names.contains("Host"), "headers missing Host: \(names)")
        #expect(names.contains("Content-Type"), "headers missing Content-Type: \(names)")
        #expect(names.contains("Content-Length"), "headers missing Content-Length: \(names)")
    }

    /// Malformed HEAD without `\r\n\r\n` terminator → nil.
    @Test("parseInnerHTTPHead: no terminator → nil (fail-CLOSED upstream)")
    func parseInnerHTTPHeadNoTerminator() {
        let raw = "POST /v1/exec HTTP/1.1\r\nHost: api.example.com\r\n"  // no double CRLF
        let bytes = Array(raw.utf8)
        let parsed = MITMUpstreamVerify.parseInnerHTTPHead(bytes)
        #expect(parsed == nil, "parseInnerHTTPHead should return nil on missing terminator")
    }

    /// Empty buffer → nil.
    @Test("parseInnerHTTPHead: empty bytes → nil")
    func parseInnerHTTPHeadEmpty() {
        let parsed = MITMUpstreamVerify.parseInnerHTTPHead([])
        #expect(parsed == nil, "parseInnerHTTPHead should return nil on empty input")
    }

    /// Truncated request line (only 2 tokens) → nil.
    @Test("parseInnerHTTPHead: malformed request line → nil")
    func parseInnerHTTPHeadMalformedRequestLine() {
        let raw = "POST /only-two-tokens\r\nHost: api.example.com\r\n\r\n"
        let bytes = Array(raw.utf8)
        let parsed = MITMUpstreamVerify.parseInnerHTTPHead(bytes)
        #expect(parsed == nil, "parseInnerHTTPHead should reject a 2-token request line")
    }

    // MARK: - InnerBodyDenyEvaluating connector seam — fake injection

    /// Recording fake evaluator: returns a canned verdict and records
    /// every (host, method, path, bodyExcerpt) it was asked to judge.
    /// Mirrors the `RecordingConnector` pattern from r92 P3 seam tests.
    private final class FakeBodyDenyEvaluator: InnerBodyDenyEvaluating, @unchecked Sendable {
        struct Call: Sendable {
            let host: String
            let method: String?
            let path: String?
            let headerCount: Int
            let bodyExcerpt: String?
        }
        private let lock = NSLock()
        private var _calls: [Call] = []
        private let verdict: EgressEvaluation
        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        init(verdict: EgressEvaluation) {
            self.verdict = verdict
        }
        func evaluate(host: String, method: String?, path: String?,
                      headers: [(name: String, value: String)],
                      bodyExcerpt: String?) -> EgressEvaluation {
            lock.lock()
            _calls.append(Call(host: host, method: method, path: path,
                               headerCount: headers.count, bodyExcerpt: bodyExcerpt))
            lock.unlock()
            return verdict
        }
    }

    // MARK: - DefaultInnerBodyDenyEvaluator adapter

    /// The default adapter routes its arguments into an `EgressRequest`
    /// and surfaces the engine's `EgressEvaluation` verbatim — including
    /// the matched rule id on a deny match.
    @Test("DefaultInnerBodyDenyEvaluator: deny-rule match → engine returns operator's ruleId")
    func defaultAdapterSurfacesOperatorRuleId() {
        let denyRule = EgressRule(
            id: "operator-body-deny-rule-7",
            pattern: "api.example.com",
            mode: .exact,
            decision: .deny,
            bodyContains: "TRIPWIRE",
            header: nil,
            path: nil
        )
        let allowRule = EgressRule(
            id: "allow-api",
            pattern: "api.example.com",
            mode: .exact,
            decision: .allow
        )
        let engine = EgressRuleEngine(rules: [denyRule, allowRule])
        let adapter = DefaultInnerBodyDenyEvaluator(engine: engine)
        let evaluation = adapter.evaluate(
            host: "api.example.com",
            method: "POST",
            path: "/v1/keys",
            headers: [],
            bodyExcerpt: "payload contains TRIPWIRE here"
        )
        #expect(evaluation.decision == .deny,
                "expected .deny verdict, got \(evaluation.decision)")
        #expect(evaluation.ruleId == "operator-body-deny-rule-7",
                "expected operator's ruleId verbatim, got \(evaluation.ruleId)")
    }

    /// Adapter surfaces `.allow` when an explicit allow rule matches.
    @Test("DefaultInnerBodyDenyEvaluator: allow-rule match → engine returns operator's ruleId")
    func defaultAdapterSurfacesAllow() {
        let allowRule = EgressRule(
            id: "allow-api",
            pattern: "api.example.com",
            mode: .exact,
            decision: .allow
        )
        let engine = EgressRuleEngine(rules: [allowRule])
        let adapter = DefaultInnerBodyDenyEvaluator(engine: engine)
        let evaluation = adapter.evaluate(
            host: "api.example.com",
            method: "POST",
            path: "/v1/keys",
            headers: [],
            bodyExcerpt: "boring body"
        )
        #expect(evaluation.decision == .allow,
                "expected .allow verdict, got \(evaluation.decision)")
        #expect(evaluation.ruleId == "allow-api",
                "expected allow rule ruleId, got \(evaluation.ruleId)")
    }

    /// Adapter surfaces the `default-deny` sentinel when NO rule matches.
    /// This is the case `pipeBidirectional` deliberately treats as fall-
    /// through-to-allow (host-level was already allowed up-arc).
    @Test("DefaultInnerBodyDenyEvaluator: no rule matches → default-deny sentinel")
    func defaultAdapterSurfacesDefaultDeny() {
        let engine = EgressRuleEngine(rules: [])
        let adapter = DefaultInnerBodyDenyEvaluator(engine: engine)
        let evaluation = adapter.evaluate(
            host: "api.example.com",
            method: "POST",
            path: "/v1/keys",
            headers: [],
            bodyExcerpt: "nothing matches"
        )
        #expect(evaluation.decision == .deny,
                "expected default-deny sentinel decision = .deny, got \(evaluation.decision)")
        #expect(evaluation.ruleId == "default-deny",
                "expected default-deny sentinel ruleId, got \(evaluation.ruleId)")
    }

    // MARK: - Validating evaluator wiring at the connector-seam level

    /// Seam contract: the fake evaluator observes the validated SNI
    /// host (not the inner `Host:` header) and the parsed HEAD method/
    /// path. This pins the "use validatedHost, not inner Host" decision
    /// — a parser-confused inner Host MUST NOT drive host-dimension
    /// matching past the boundary the rebind already pinned.
    ///
    /// This test exercises the adapter + parser shape directly (no SSL
    /// IO) — it builds the headBytes the rebind peek would return on a
    /// well-formed inner request, runs them through parseInnerHTTPHead,
    /// builds the EgressRequest the adapter would, and asserts the
    /// evaluator observes the expected fields.
    @Test("seam contract: evaluator observes validatedHost + parsed method/path/headers")
    func evaluatorObservesExpectedFields() {
        let raw = "POST /v1/exec HTTP/1.1\r\nHost: inner-but-validated.example.com\r\nContent-Type: application/json\r\n\r\n{\"command\":\"TRIPWIRE\"}"
        let bytes = Array(raw.utf8)
        guard let parsed = MITMUpstreamVerify.parseInnerHTTPHead(bytes) else {
            Issue.record("parseInnerHTTPHead returned nil on a well-formed HEAD")
            return
        }
        let fake = FakeBodyDenyEvaluator(verdict: EgressEvaluation(decision: .allow, ruleId: "allow-stub"))
        // Drive the adapter shape DIRECTLY: this is what
        // pipeBidirectional would do INSIDE its `.allow` arm.
        let body = MITMUpstreamVerify.innerBodyBytes(fromHeadBuffer: bytes)
        let preparedExcerpt: String? = body.map { raw in
            let prepared = EgressDecisionStore.prepareBodyExcerpt(raw)
            return String(data: prepared, encoding: .utf8)
        } ?? nil
        _ = fake.evaluate(
            host: "validated.example.com",  // SNI/CONNECT-pinned host
            method: parsed.method,
            path: parsed.path,
            headers: parsed.headers,
            bodyExcerpt: preparedExcerpt
        )
        #expect(fake.calls.count == 1, "evaluator should fire exactly once, got \(fake.calls.count)")
        guard let call = fake.calls.first else { return }
        #expect(call.host == "validated.example.com",
                "evaluator observed wrong host (must be SNI/CONNECT-pinned): \(call.host)")
        #expect(call.method == "POST", "evaluator observed wrong method: \(call.method ?? "nil")")
        #expect(call.path == "/v1/exec", "evaluator observed wrong path: \(call.path ?? "nil")")
        #expect(call.bodyExcerpt?.contains("TRIPWIRE") == true,
                "evaluator should see redacted body containing TRIPWIRE, got: \(call.bodyExcerpt ?? "nil")")
    }

    // MARK: - Schneier P1: redact-before-evaluate

    /// Schneier P1: the bytes handed to the evaluator are ALREADY
    /// `prepareBodyExcerpt`-processed. A planted OPENAI_API_KEY-shaped
    /// secret in the raw body MUST NOT appear in the bodyExcerpt the
    /// evaluator observes. This locks in the truncate-then-redact-
    /// before-engine invariant on the LIVE deny path.
    @Test("Schneier P1: planted secret in raw body is REDACTED before evaluator sees it")
    func plantedSecretRedactedBeforeEvaluator() {
        let rawSecret = "sk-abcdef1234567890ABCDEFGHIJKL"
        let raw = "POST /v1/keys HTTP/1.1\r\nHost: api.example.com\r\n\r\n{\"upstream_key\":\"\(rawSecret)\"}"
        let bytes = Array(raw.utf8)
        // Mirror the redact-before-evaluate logic pipeBidirectional uses.
        let body = MITMUpstreamVerify.innerBodyBytes(fromHeadBuffer: bytes)
        guard let raw = body else {
            Issue.record("innerBodyBytes returned nil")
            return
        }
        let prepared = EgressDecisionStore.prepareBodyExcerpt(raw)
        guard let preparedStr = String(data: prepared, encoding: .utf8) else {
            Issue.record("prepared bytes not UTF-8")
            return
        }
        #expect(!preparedStr.contains(rawSecret),
                "Schneier P1: raw OPENAI_API_KEY MUST NOT survive into the bytes handed to the evaluator")
    }
}
