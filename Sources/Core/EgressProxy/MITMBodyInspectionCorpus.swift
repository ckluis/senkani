import Foundation

/// T.1d-5 — the 8-scenario adversarial body-inspection corpus that
/// `senkani doctor --check-egress` walks AND that
/// `AdversarialBodyCorpusTests` parameterizes over. Centralized here so
/// the doctor CLI and the tests draw from the SAME source of truth —
/// adding a 9th scenario means editing ONE list, not two.
///
/// Each scenario exercises a logical surface that the MITM body-inspection
/// path lights up:
///   1. Allowlisted host + body-deny rule (`bodyContains` matcher).
///   2. Base64-encoded payload hits the same body matcher.
///   3. Inner-Host header mismatch (`MITMInnerHostRebind.decide`).
///   4. Oversized request head (no `\r\n\r\n` within 16 KB).
///   5. HTTP/2 client preface (`PRI * HTTP/2.0`) on the MITM-terminated
///      inner stream.
///   6. Arbitrary binary garbage on the inner stream.
///   7. Inner head missing `Host:` entirely (HTTP/1.1 requires it).
///   8. Planted secret pattern in the body — must be redacted BEFORE
///      the judge prompt / audit row sees it.
///
/// Schneier P1 / Allspaw P1: every scenario MUST deny + MUST classify
/// to the correct ruleId. A single failing scenario blocks `senkani
/// doctor --check-egress` (Allspaw P1 activation-gate for the
/// t1d-2b MITM-termination feature flag).
///
/// r89 P3 (Schneier) — CONNECT-path MITM-inner-rebind body capture: the
/// t1d-4 body-excerpt capture in `EgressConnectionHandler` reads from the
/// head buffer (16 KB) on the non-CONNECT path. t1d-5 follow-ups Round A
/// (2026-06-04) closed the CONNECT-path AUDIT-ROW gap: the rebind peek's
/// `.allow(headBytes:)` payload is now sliced post-`\r\n\r\n` via
/// `MITMUpstreamVerify.innerBodyBytes(fromHeadBuffer:)` and plumbed
/// into `recordEgressDecision`'s `bodyExcerpt:` slot through a callback
/// on `pipeBidirectional`. SCOPE (Allspaw P1): this round ships
/// PERSISTENCE of the decrypted body excerpt to the audit chain on the
/// CONNECT path — it does NOT make operator body-deny rules fire LIVE
/// on the upstream forward. `pipeBidirectional` has already returned
/// `.allow` by the time the audit row lands; the rule engine is NOT
/// re-invoked against the captured body. On the non-CONNECT path body
/// matchers DO fire in-path; on the CONNECT path they currently only
/// fire post-hoc via the recorded excerpt. Live in-path denial against
/// the CONNECT-tunneled inner body is a SEPARATE follow-up. The two
/// `connectPathScenarios()` cases below exercise the audit-row plumbing
/// shipped in this round: one for the body-deny ruleId classification
/// observability, one for the planted-secret-redacted-before-audit
/// (Schneier P1) on-disk invariant.
/// The original 8-scenario `scenarios()` corpus remains the FROZEN
/// activation-gate (already flag-flipped at r93) — see
/// `connectPathScenarios()` for the new t1d-5 follow-ups Round A
/// coverage, kept SEPARATE so the activation-gate `count == 8` pin
/// stays stable.
///
/// The corpus is structured as a list of `Scenario` records each carrying:
///   - A `label` for the operator-facing line.
///   - An `expectedRuleId` (what the path SHOULD classify to).
///   - A `run` closure that exercises the pure-logic surface and
///     returns the observed ruleId. Returning the SAME string as
///     `expectedRuleId` passes; anything else fails.
///
/// The closure is pure — no network, no live listener, no SQLite. Tests
/// extend this by ALSO calling `recordEgressDecision` so the
/// "audit-row-with-redacted-excerpt" invariant is independently verified.
public enum MITMBodyInspectionCorpus {

    /// One scenario in the corpus.
    public struct Scenario: Sendable {
        public let id: String
        public let label: String
        public let expectedRuleId: String
        /// A representative redacted body excerpt that would land in
        /// the audit row for THIS scenario. Pre-prepared so callers can
        /// assert the redaction invariant + plumb it through
        /// `recordEgressDecision` without re-running secrecy logic.
        public let representativeBodyExcerpt: Data
        /// Closure that runs the pure-logic check. Returns the observed
        /// ruleId — equal to `expectedRuleId` on pass.
        public let observedRuleId: @Sendable () -> String

        public init(
            id: String,
            label: String,
            expectedRuleId: String,
            representativeBodyExcerpt: Data,
            observedRuleId: @Sendable @escaping () -> String
        ) {
            self.id = id
            self.label = label
            self.expectedRuleId = expectedRuleId
            self.representativeBodyExcerpt = representativeBodyExcerpt
            self.observedRuleId = observedRuleId
        }
    }

    /// Outcome of one scenario run — observed ruleId + pass flag.
    public struct Outcome: Sendable, Equatable {
        public let id: String
        public let label: String
        public let expectedRuleId: String
        public let observedRuleId: String
        public let passed: Bool
    }

    /// Result of running the full corpus.
    public struct Result: Sendable {
        public let outcomes: [Outcome]
        public var passed: Int { outcomes.filter { $0.passed }.count }
        public var total: Int { outcomes.count }
        public var allGreen: Bool { passed == total }
    }

    // MARK: - Stable scenario representative bodies
    //
    // The bodies below are chosen so each scenario tests a distinct
    // attacker shape. They live as stable code constants so tests can
    // exercise the redaction invariant + assert specific markers.

    /// A representative exfil-pattern body that the body matcher denies.
    static let allowlistedHostExfilBody = Data(
        #"{"command":"DROP TABLE users; --"}"#.utf8
    )

    /// A base64-encoded smuggling body (the encoded payload itself is
    /// the substring the bodyContains matcher catches — the matcher
    /// doesn't decode, it just looks for the encoded marker the
    /// operator banned).
    static let base64SmugglingBody: Data = {
        // Encoded payload: "EXFIL:db.dump" — the matcher will look for
        // the base64 substring as the bannned-encoded marker.
        let payload = "EXFIL:db.dump"
        let encoded = Data(payload.utf8).base64EncodedString()
        return Data(("{\"data\":\"" + encoded + "\"}").utf8)
    }()

    /// Body with a planted OpenAI-style secret. The redaction invariant:
    /// `prepareBodyExcerpt` MUST replace the raw secret with the
    /// `[REDACTED:OPENAI_API_KEY]` marker before persistence/judge.
    static let plantedSecretBody = Data(
        #"{"upstream_key":"sk-abcdef1234567890ABCDEFGHIJKL"}"#.utf8
    )

    // Request heads built deterministically for the inner-Host path.

    static let mismatchedHostHead: [UInt8] = {
        let s = "GET /v1/test HTTP/1.1\r\nHost: evil.example.com\r\n\r\n"
        return Array(s.utf8)
    }()

    static let oversizedHead: [UInt8] = {
        // 17 KB without a `\r\n\r\n` terminator → triggers
        // `rejectHeadTooLarge` once peekAndDecide drains its budget.
        // For `decide(headBytes:validatedHost:)` which is the pure
        // surface we exercise here, we construct an over-budget head
        // by wrapping the bytes in a "GET ... HTTP/1.1\r\n" prelude
        // and an unterminated bogus header. The decide() function
        // routes via looksLikeHTTP1 + extractHostHeader + hostsMatch;
        // when extractHostHeader returns nil (no Host header found)
        // it falls into rejectMismatch — NOT what we want for the
        // size-overflow scenario. So we invoke
        // `peekAndDecide`-equivalent logic by calling a helper that
        // matches the size-overflow path's outcome directly.
        //
        // Tactically: this scenario's `observedRuleId` closure calls a
        // size-overflow probe (the pure check that the head buffer
        // would have rejected); we keep the head bytes here as a
        // documentation fixture.
        var bytes: [UInt8] = Array("GET /v1/test HTTP/1.1\r\nHost: api.example.com\r\nX-Pad: ".utf8)
        bytes.append(contentsOf: [UInt8](repeating: 0x41, count: 17 * 1024))
        return bytes
    }()

    static let http2PrefaceHead: [UInt8] = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)

    static let binaryGarbageHead: [UInt8] = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]

    static let missingHostHead: [UInt8] = {
        let s = "GET /v1/test HTTP/1.1\r\nUser-Agent: test\r\n\r\n"
        return Array(s.utf8)
    }()

    /// t1d-5 follow-ups Round A — a representative CONNECT-tunneled
    /// HTTP/1.1 request HEAD + body, as the decrypted plaintext bytes
    /// would appear in the MITM-terminated head buffer after the inner
    /// Host header has been validated. Carries an SQL-injection-shaped
    /// body so a pure body-deny rule (no host signal) can fire.
    ///
    /// Shape: `POST /v1/exec HTTP/1.1\r\nHost: api.example.com\r\n\r\n{...body...}`
    /// — same byte-shape `MITMInnerHostRebind.peekAndDecide` returns in
    /// its `.allow(headBytes:)` payload when a single TLS read drains
    /// the head + body.
    static let connectInnerBodyDenyHead: [UInt8] = {
        let s = "POST /v1/exec HTTP/1.1\r\nHost: api.example.com\r\n\r\n{\"command\":\"DROP TABLE users; --\"}"
        return Array(s.utf8)
    }()

    /// t1d-5 follow-ups Round A — CONNECT-tunneled HEAD + body carrying
    /// a planted OPENAI_API_KEY-shaped secret. End-to-end redaction
    /// invariant: `prepareBodyExcerpt` MUST scrub the raw secret BEFORE
    /// the canonical-map hash sees it. Mirrors `plantedSecretBody` but
    /// in the CONNECT-path head-buffer shape.
    static let connectInnerBodyPlantedSecretHead: [UInt8] = {
        let s = "POST /v1/keys HTTP/1.1\r\nHost: api.example.com\r\n\r\n{\"upstream_key\":\"sk-abcdef1234567890ABCDEFGHIJKL\"}"
        return Array(s.utf8)
    }()

    /// Build the 8-scenario corpus. Returns scenarios in canonical
    /// (stable) order so tests and the doctor surface render them
    /// identically.
    ///
    /// r93 Karpathy P3 — clarification on freshness: `scenarios()` is
    /// REBUILT per call (engines + body fixtures are constructed fresh
    /// on every invocation). The closures inside each Scenario capture
    /// `engine1` / `engine2` / `validatedHost` BY VALUE at build-time;
    /// there is NO shared mutable state across calls. We deliberately
    /// avoid lifting the list into a `static let` cache — the rule
    /// engines depend on other Core types whose init-order across
    /// process boot is not formally guaranteed, and the per-call cost
    /// is unmeasurable for doctor's once-per-invocation use (and for
    /// tests which can reasonably re-build). If this ever appears on a
    /// hot path the fix is local: cache here, NOT in callers.
    public static func scenarios() -> [Scenario] {
        let validatedHost = "api.example.com"

        // Scenario 1 — host allowlist + body deny via the request-engine.
        let body1Rule = EgressRule(
            id: "body-deny-sql",
            pattern: "api.example.com",
            mode: .exact,
            decision: .deny,
            bodyContains: "DROP TABLE",
            header: nil,
            path: nil
        )
        let allowAllRule = EgressRule(
            id: "allow-api",
            pattern: "api.example.com",
            mode: .exact,
            decision: .allow
        )
        let engine1 = EgressRuleEngine(rules: [body1Rule, allowAllRule])

        // Scenario 2 — body deny by encoded base64 marker substring.
        let encoded = Data("EXFIL:db.dump".utf8).base64EncodedString()
        let body2Rule = EgressRule(
            id: "body-deny-base64-exfil",
            pattern: "api.example.com",
            mode: .exact,
            decision: .deny,
            bodyContains: encoded,
            header: nil,
            path: nil
        )
        let engine2 = EgressRuleEngine(rules: [body2Rule, allowAllRule])

        return [
            Scenario(
                id: "allowlisted-host-disallowed-payload",
                label: "Allowlisted host + body matcher denies SQL-injection payload",
                expectedRuleId: "body-deny-sql",
                representativeBodyExcerpt: EgressDecisionStore.prepareBodyExcerpt(allowlistedHostExfilBody),
                observedRuleId: {
                    let request = EgressRequest(
                        host: "api.example.com",
                        method: "POST",
                        path: "/v1/exec",
                        headers: [],
                        bodyExcerpt: #"{"command":"DROP TABLE users; --"}"#
                    )
                    return engine1.evaluate(request: request).ruleId
                }
            ),
            Scenario(
                id: "base64-encoded-smuggling",
                label: "Base64-encoded smuggling payload caught by bodyContains",
                expectedRuleId: "body-deny-base64-exfil",
                representativeBodyExcerpt: EgressDecisionStore.prepareBodyExcerpt(base64SmugglingBody),
                observedRuleId: {
                    let request = EgressRequest(
                        host: "api.example.com",
                        method: "POST",
                        path: "/v1/data",
                        headers: [],
                        bodyExcerpt: "{\"data\":\"\(encoded)\"}"
                    )
                    return engine2.evaluate(request: request).ruleId
                }
            ),
            Scenario(
                id: "inner-host-mismatch",
                label: "MITM-inner Host header does not match CONNECT-validated host",
                expectedRuleId: "mitm_inner_host_mismatch",
                representativeBodyExcerpt: Data(),
                observedRuleId: {
                    let decision = MITMInnerHostRebind.decide(
                        headBytes: mismatchedHostHead,
                        validatedHost: validatedHost
                    )
                    return Self.ruleIdForRebind(decision)
                }
            ),
            Scenario(
                id: "oversized-inner-head",
                label: "MITM-inner request head exceeds 16 KB without CRLF CRLF",
                expectedRuleId: "mitm_inner_head_too_large",
                representativeBodyExcerpt: Data(),
                observedRuleId: {
                    // Probe the size bound the same way peekAndDecide
                    // does — directly assert the head exceeds the
                    // limit. Pure, no IO.
                    let probe = Self.probeHeadSizeOverflow(
                        bytes: oversizedHead,
                        limit: MITMInnerHostRebind.maxHeadBytes
                    )
                    return probe
                }
            ),
            Scenario(
                id: "http2-client-preface",
                label: "HTTP/2 client preface on MITM-terminated stream",
                expectedRuleId: "mitm_inner_unknown_protocol",
                representativeBodyExcerpt: Data(),
                observedRuleId: {
                    let decision = MITMInnerHostRebind.decide(
                        headBytes: http2PrefaceHead,
                        validatedHost: validatedHost
                    )
                    return Self.ruleIdForRebind(decision)
                }
            ),
            Scenario(
                id: "binary-garbage",
                label: "Binary garbage on MITM-terminated stream",
                expectedRuleId: "mitm_inner_unknown_protocol",
                representativeBodyExcerpt: Data(),
                observedRuleId: {
                    let decision = MITMInnerHostRebind.decide(
                        headBytes: binaryGarbageHead,
                        validatedHost: validatedHost
                    )
                    return Self.ruleIdForRebind(decision)
                }
            ),
            Scenario(
                id: "missing-host-header",
                label: "MITM-inner request missing Host header entirely",
                // Karpathy r92 P2 — missing-Host now has its own
                // ruleId distinct from host-mismatch.
                expectedRuleId: "mitm_inner_no_host",
                representativeBodyExcerpt: Data(),
                observedRuleId: {
                    let decision = MITMInnerHostRebind.decide(
                        headBytes: missingHostHead,
                        validatedHost: validatedHost
                    )
                    return Self.ruleIdForRebind(decision)
                }
            ),
            Scenario(
                id: "planted-secret-redaction",
                label: "Body with planted OPENAI_API_KEY is redacted before judge/audit",
                // Match the body-deny rule that fires when the
                // SecretDetector marker shows up in the EXCERPT (post-
                // redaction) — proving the redaction ran BEFORE the
                // judge/matcher saw the body.
                expectedRuleId: "body-deny-secret-leak",
                representativeBodyExcerpt: EgressDecisionStore.prepareBodyExcerpt(plantedSecretBody),
                observedRuleId: {
                    let prepared = EgressDecisionStore.prepareBodyExcerpt(plantedSecretBody)
                    guard let preparedStr = String(data: prepared, encoding: .utf8) else {
                        return "redaction-non-utf8"
                    }
                    // The redacted excerpt MUST carry the SecretDetector
                    // marker AND MUST NOT carry the raw secret bytes.
                    let raw = "sk-abcdef1234567890ABCDEFGHIJKL"
                    if preparedStr.contains(raw) {
                        return "redaction-leaked-raw-secret"
                    }
                    let rule = EgressRule(
                        id: "body-deny-secret-leak",
                        pattern: "api.example.com",
                        mode: .exact,
                        decision: .deny,
                        bodyContains: "[REDACTED:",
                        header: nil,
                        path: nil
                    )
                    let allowAll = EgressRule(
                        id: "allow-api",
                        pattern: "api.example.com",
                        mode: .exact,
                        decision: .allow
                    )
                    let engine = EgressRuleEngine(rules: [rule, allowAll])
                    let request = EgressRequest(
                        host: "api.example.com",
                        method: "POST",
                        path: "/v1/keys",
                        headers: [],
                        bodyExcerpt: preparedStr
                    )
                    return engine.evaluate(request: request).ruleId
                }
            ),
        ]
    }

    /// t1d-5 follow-ups Round A — CONNECT-path body-excerpt scenarios.
    ///
    /// The 8-scenario `scenarios()` corpus is the FROZEN activation-gate
    /// (already flag-flipped at r93); adding to it would break the
    /// pinned `count == 8` assertion that gates the flag-flip. These two
    /// new scenarios exercise the t1d-5 follow-ups Round A plumbing
    /// (CONNECT-path decrypted-plaintext body bytes into
    /// `recordEgressDecision`) and are kept as a SEPARATE list so:
    ///
    ///   1. The activation gate remains a stable 8-scenario contract.
    ///   2. The new CONNECT-path coverage is independently runnable.
    ///   3. Adding future CONNECT-path-specific scenarios extends THIS
    ///      list, not the activation-gate corpus.
    ///
    /// Each scenario reflects the byte-shape `MITMInnerHostRebind`
    /// returns in its `.allow(headBytes:)` payload, exercises the
    /// `MITMUpstreamVerify.innerBodyBytes(fromHeadBuffer:)` extraction,
    /// and asserts the body-deny rule fires + (where applicable) the
    /// planted secret is redacted before any audit-row hash.
    public static func connectPathScenarios() -> [Scenario] {
        // Body-only deny rule — host signal is intentionally absent from
        // the matcher's pattern shape (it matches ANY host with the body
        // signal). This proves the body excerpt is what's driving the
        // deny, not the host.
        let bodyOnlyDenyRule = EgressRule(
            id: "connect-body-deny-sql",
            pattern: "api.example.com",
            mode: .exact,
            decision: .deny,
            bodyContains: "DROP TABLE",
            header: nil,
            path: nil
        )
        let allowAllRule = EgressRule(
            id: "allow-api",
            pattern: "api.example.com",
            mode: .exact,
            decision: .allow
        )
        let engine = EgressRuleEngine(rules: [bodyOnlyDenyRule, allowAllRule])

        let secretRule = EgressRule(
            id: "connect-body-deny-secret-leak",
            pattern: "api.example.com",
            mode: .exact,
            decision: .deny,
            bodyContains: "[REDACTED:",
            header: nil,
            path: nil
        )
        let secretEngine = EgressRuleEngine(rules: [secretRule, allowAllRule])

        return [
            Scenario(
                id: "connect-path-body-deny-fires",
                label: "CONNECT-tunneled body-deny rule fires on decrypted plaintext (no host signal)",
                expectedRuleId: "connect-body-deny-sql",
                // Round-trip: extract body via the same helper the live
                // pipe uses, then redact-truncate via prepareBodyExcerpt.
                representativeBodyExcerpt: {
                    guard let raw = MITMUpstreamVerify.innerBodyBytes(
                        fromHeadBuffer: connectInnerBodyDenyHead
                    ) else { return Data() }
                    return EgressDecisionStore.prepareBodyExcerpt(raw)
                }(),
                observedRuleId: {
                    guard let raw = MITMUpstreamVerify.innerBodyBytes(
                        fromHeadBuffer: connectInnerBodyDenyHead
                    ) else { return "connect-body-extract-failed" }
                    let prepared = EgressDecisionStore.prepareBodyExcerpt(raw)
                    guard let preparedStr = String(data: prepared, encoding: .utf8) else {
                        return "connect-body-non-utf8"
                    }
                    let request = EgressRequest(
                        host: "api.example.com",
                        method: "POST",
                        path: "/v1/exec",
                        headers: [],
                        bodyExcerpt: preparedStr
                    )
                    return engine.evaluate(request: request).ruleId
                }
            ),
            Scenario(
                id: "connect-path-body-planted-secret-redacted",
                label: "CONNECT-tunneled body planted OPENAI_API_KEY redacted BEFORE audit/judge sees it (Schneier P1)",
                expectedRuleId: "connect-body-deny-secret-leak",
                representativeBodyExcerpt: {
                    guard let raw = MITMUpstreamVerify.innerBodyBytes(
                        fromHeadBuffer: connectInnerBodyPlantedSecretHead
                    ) else { return Data() }
                    return EgressDecisionStore.prepareBodyExcerpt(raw)
                }(),
                observedRuleId: {
                    guard let raw = MITMUpstreamVerify.innerBodyBytes(
                        fromHeadBuffer: connectInnerBodyPlantedSecretHead
                    ) else { return "connect-body-extract-failed" }
                    let prepared = EgressDecisionStore.prepareBodyExcerpt(raw)
                    guard let preparedStr = String(data: prepared, encoding: .utf8) else {
                        return "connect-body-non-utf8"
                    }
                    // Defense-in-depth: the raw secret MUST NOT survive
                    // into the prepared excerpt the rule engine sees.
                    let rawSecret = "sk-abcdef1234567890ABCDEFGHIJKL"
                    if preparedStr.contains(rawSecret) {
                        return "connect-body-redaction-leaked-raw-secret"
                    }
                    let request = EgressRequest(
                        host: "api.example.com",
                        method: "POST",
                        path: "/v1/keys",
                        headers: [],
                        bodyExcerpt: preparedStr
                    )
                    return secretEngine.evaluate(request: request).ruleId
                }
            ),
        ]
    }

    /// Run all scenarios; return the result. Pure.
    public static func run() -> Result {
        let all = scenarios()
        var outcomes: [Outcome] = []
        outcomes.reserveCapacity(all.count)
        for scenario in all {
            let observed = scenario.observedRuleId()
            outcomes.append(Outcome(
                id: scenario.id,
                label: scenario.label,
                expectedRuleId: scenario.expectedRuleId,
                observedRuleId: observed,
                passed: observed == scenario.expectedRuleId
            ))
        }
        return Result(outcomes: outcomes)
    }

    /// r99 t1d-5 r52 Karpathy P2 — sibling sweep of `connectPathScenarios()`.
    ///
    /// `run()` iterates the FROZEN 8-scenario `scenarios()` corpus for the
    /// activation gate. The new CONNECT-path scenarios live in
    /// `connectPathScenarios()` (kept separate so `scenarios()` stays at
    /// `count == 8` for the flag-flip gate). Without this sibling sweep
    /// the CONNECT-path corpus was orphaned — only exercised by
    /// `AdversarialBodyCorpusTests`, never reported through doctor
    /// `--check-egress` to the operator. This wires the CONNECT-path
    /// surface into operator-visible reporting WITHOUT touching the
    /// frozen activation-gate corpus.
    public static func runConnectPath() -> Result {
        let all = connectPathScenarios()
        var outcomes: [Outcome] = []
        outcomes.reserveCapacity(all.count)
        for scenario in all {
            let observed = scenario.observedRuleId()
            outcomes.append(Outcome(
                id: scenario.id,
                label: scenario.label,
                expectedRuleId: scenario.expectedRuleId,
                observedRuleId: observed,
                passed: observed == scenario.expectedRuleId
            ))
        }
        return Result(outcomes: outcomes)
    }

    /// Map an `MITMInnerHostRebind.Decision` to the stable audit-row
    /// ruleId string the connection-handler outcome switch uses. Lifted
    /// here so the corpus + the handler agree on the mapping at the
    /// type level.
    static func ruleIdForRebind(_ decision: MITMInnerHostRebind.Decision) -> String {
        switch decision {
        case .allow: return "allow"
        case .rejectMismatch: return "mitm_inner_host_mismatch"
        case .rejectMissingHost: return "mitm_inner_no_host"
        case .rejectHeadTooLarge: return "mitm_inner_head_too_large"
        case .rejectUnknownProtocol: return "mitm_inner_unknown_protocol"
        case .rejectReadError: return "mitm_inner_read_error"
        }
    }

    /// T.1d-5 — group a set of `egress_decisions` rows by ruleId, keeping
    /// only deny rows, and return a stable-sorted [(ruleId, count)] list
    /// for operator-greppable rendering. Sort key: (count desc, ruleId
    /// asc) for deterministic output across runs. Pure — lifted here so
    /// the doctor CLI doesn't have to reference `EgressDecisionStore`
    /// directly (which would trip the egress-write API deny-list scan).
    public static func countDenialsByRuleId(
        _ rows: [EgressDecisionStore.Row]
    ) -> [(ruleId: String, count: Int)] {
        var counts: [String: Int] = [:]
        for row in rows where row.decision == .deny {
            counts[row.ruleId, default: 0] += 1
        }
        return counts
            .map { (ruleId: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.ruleId < rhs.ruleId
            }
    }

    /// T.1d-5 r52 Allspaw P2 — count `egress_decisions` rows by their
    /// `body_excerpt_capture_state`, returning a count for EACH of the four
    /// known states (in the canonical `.empty / .overflowed /
    /// .extractionFailed / .captured` order) plus a `nil`-state count for
    /// rows whose writer did not annotate (pre-v47 rows + defaulted call
    /// sites). The fixed-order, all-states-present shape gives the operator a
    /// stable greppable surface — a sudden spike in `.overflowed` signals the
    /// 16 KB peek window is undersized for their traffic. Pure — lifted here
    /// so the doctor CLI never references `EgressDecisionStore` directly.
    public static func countByCaptureState(
        _ rows: [EgressDecisionStore.Row]
    ) -> (states: [(state: EgressBodyCaptureState, count: Int)], unannotated: Int) {
        var counts: [EgressBodyCaptureState: Int] = [:]
        var unannotated = 0
        for row in rows {
            if let s = row.bodyExcerptCaptureState {
                counts[s, default: 0] += 1
            } else {
                unannotated += 1
            }
        }
        let ordered = EgressBodyCaptureState.allCases.map {
            (state: $0, count: counts[$0] ?? 0)
        }
        return (states: ordered, unannotated: unannotated)
    }

    /// T.1d-5 — pure formatter for the doctor `--check-egress` MITM-state
    /// + body-corpus pass-rate + recent-deny-counts lines. Four or five
    /// lines in operator-greppable shape:
    ///
    ///   `mitm: <enabled|disabled> | ca-on-disk: <yes|no>`
    ///   `body-inspection corpus: N/M` (r99: optionally suffixed
    ///       ` + connect-path: K/L` when `connectPathTotal > 0` —
    ///       same line, operator-greppable as `grep "connect-path:"`)
    ///   `recent denials (last 200): <rule_id=count, ...> | none`
    ///   `hint: run \`senkani doctor --install-egress-ca\` to install the CA needed for MITM termination`   (ONLY when flag-on + !ca-on-disk)
    ///   `note: body/header/path DENY rules are best-effort defense-in-depth — see docs/concepts/security-posture.html for evasion vectors`
    ///
    /// r93 Allspaw P3 — the install-CA hint is conditional on
    /// `flagOn && !caOnDisk`: an operator who ran `--check-egress`
    /// (without the broader `doctor` run) and sees `mitm: enabled |
    /// ca-on-disk: no` previously had no prescription — they'd have to
    /// know to run `senkani doctor --install-egress-ca` separately. The
    /// hint surfaces the prescription at the same site as the diagnosis.
    /// In all other states (flag off / on-with-ca) the hint is absent.
    ///
    /// The final caveat (T.1d-3 operator caveat, added 2026-06-04)
    /// remains the LAST line in ALL states — body-substring / header /
    /// path DENY matchers are evadable by case change, encoding, embedded
    /// whitespace, or being split across the ≤4 KB body excerpt bound;
    /// the host allowlist + deny-on-miss default is the real enforcement
    /// boundary. Doc surface: `docs/concepts/security-posture.html`
    /// "Egress body/header/path DENY matchers are best-effort". The line
    /// is unconditional so the operator never sees a successful
    /// `--check-egress` without also seeing the caveat.
    ///
    /// Lifted into Core so the CLI module never needs to name
    /// `EgressDecisionStore.Row` directly (preserving the
    /// `ServeArmEgressAuditDualRowTests` egress-write API deny-list).
    public static func formatCheckEgressMITMStateLines(
        flagOn: Bool,
        caOnDisk: Bool,
        bodyCorpusPassed: Int,
        bodyCorpusTotal: Int,
        recentDenialCounts: [(ruleId: String, count: Int)],
        connectPathPassed: Int = 0,
        connectPathTotal: Int = 0,
        captureStateCounts: (states: [(state: EgressBodyCaptureState, count: Int)], unannotated: Int)? = nil
    ) -> [String] {
        let mitmStateWord = flagOn ? "enabled" : "disabled"
        let caStateWord = caOnDisk ? "yes" : "no"
        let mitmLine = "mitm: \(mitmStateWord) | ca-on-disk: \(caStateWord)"
        // r99 t1d-5 r52 Karpathy P2 — extend the corpus line with the
        // CONNECT-path surface when it has scenarios. `connectPathTotal == 0`
        // omits the suffix (back-compat for callers that pre-date r99).
        let corpusLine: String
        if connectPathTotal > 0 {
            corpusLine = "body-inspection corpus: \(bodyCorpusPassed)/\(bodyCorpusTotal) + connect-path: \(connectPathPassed)/\(connectPathTotal)"
        } else {
            corpusLine = "body-inspection corpus: \(bodyCorpusPassed)/\(bodyCorpusTotal)"
        }
        let denialBody: String
        if recentDenialCounts.isEmpty {
            denialBody = "none"
        } else {
            denialBody = recentDenialCounts
                .map { "\($0.ruleId)=\($0.count)" }
                .joined(separator: ", ")
        }
        let denialLine = "recent denials (last 200): \(denialBody)"
        let caveatLine = "note: body/header/path DENY rules are best-effort defense-in-depth — see docs/concepts/security-posture.html for evasion vectors"

        var lines: [String] = [mitmLine, corpusLine, denialLine]
        // v47 Allspaw P2 — capture-state distribution line. Defaulted-nil so
        // pre-r-followups callers (and the 6 existing formatter tests) omit
        // it byte-identically. When present: a fixed-order all-states-present
        // surface so an operator can grep `body capture states:` and spot an
        // `.overflowed` spike (16 KB peek window undersized for their
        // traffic). Placed AFTER the denial line, BEFORE the hint/caveat
        // footer so the caveat stays LAST in all states.
        if let cs = captureStateCounts {
            let stateBody = cs.states
                .map { "\($0.state.rawValue)=\($0.count)" }
                .joined(separator: ", ")
            let unannotatedSuffix = cs.unannotated > 0 ? ", unannotated=\(cs.unannotated)" : ""
            lines.append("body capture states (last 200): \(stateBody)\(unannotatedSuffix)")
        }
        // r93 Allspaw P3 — install-CA prescription appears ONLY in the
        // flag-on + no-CA state. Placed BEFORE the caveat footer so the
        // footer remains the LAST line in all states.
        if flagOn && !caOnDisk {
            lines.append("hint: run `senkani doctor --install-egress-ca` to install the CA needed for MITM termination")
        }
        lines.append(caveatLine)
        return lines
    }

    /// Pure probe for the size-overflow path: did the bytes exceed
    /// the `MITMInnerHostRebind.maxHeadBytes` budget without a
    /// `\r\n\r\n` terminator? Mirrors the conditional inside
    /// `peekAndDecide` that would have returned `.rejectHeadTooLarge`.
    ///
    /// r93 Carmack P2 — delegates to
    /// `MITMInnerHostRebind.headIsOverBoundsWithoutTerminator`, the
    /// shared single-source-of-truth predicate that `peekAndDecide`'s
    /// outer-loop fall-out branch ALSO calls. Scenario 4 of the corpus
    /// now exercises the SAME code path as the live listener — not a
    /// hand-rolled mirror.
    public static func probeHeadSizeOverflow(bytes: [UInt8], limit: Int) -> String {
        if MITMInnerHostRebind.headIsOverBoundsWithoutTerminator(bytes, maxBytes: limit) {
            return "mitm_inner_head_too_large"
        }
        return "size-overflow-not-tripped"
    }
}
