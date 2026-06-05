import Testing
import Foundation
@testable import CLI
@testable import Core

/// T.1d-5 — the 8-scenario adversarial body-inspection corpus.
///
/// Each scenario exercises one logical surface that the MITM body-inspection
/// path lights up — host allow + body deny, base64 smuggling, inner-Host
/// mismatch, oversized head, HTTP/2 preface, binary garbage, missing
/// Host, planted-secret redaction. Every scenario MUST:
///
///   1. Classify to the expected ruleId via `MITMBodyInspectionCorpus.run()`.
///   2. Produce a `egress_decisions` deny row when piped through
///      `recordEgressDecision` with the prepared redacted body excerpt.
///   3. Persist a REDACTED excerpt (Schneier P1: raw secret bytes MUST
///      NEVER appear in the audit row).
///
/// Allspaw P1 / activation-gate: 8/8 GREEN is the precondition for the
/// T.1d-2b MITM-termination feature flag default flipping to ON. A single
/// failing scenario blocks the flag-flip.
///
/// The tests are `.serialized` because each constructs a temp
/// SessionDatabase that runs the full migration array (shared on-disk
/// state at fixed paths under /tmp). Mirrors `EgressBodyExcerptTests`.
@Suite("T.1d-5 — 8-scenario adversarial body-inspection corpus", .serialized)
struct AdversarialBodyCorpusTests {

    private static func tempDBPath() -> String {
        let dir = NSTemporaryDirectory() + "senkani-t1d5-adversarial-corpus/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "egress-decisions-t1d5-\(UUID().uuidString).db"
    }

    // MARK: - Whole-corpus invariants

    /// Allspaw P1 activation-gate: 8/8 scenarios MUST classify to the
    /// expected ruleId. A single failing scenario BLOCKS the
    /// flag-flip-on gate.
    @Test("Allspaw P1 ACTIVATION GATE: all 8 adversarial scenarios classify to the expected ruleId")
    func allEightScenariosClassifyCorrectly() {
        let result = MITMBodyInspectionCorpus.run()
        #expect(result.total == 8,
                "corpus must contain exactly 8 scenarios (Allspaw P1 ACTIVATION GATE)")
        #expect(result.allGreen,
                "corpus MUST be 8/8 GREEN — a single failure BLOCKS the t1d-2b MITM-termination flag flip-on")
        for outcome in result.outcomes {
            #expect(outcome.passed,
                    "scenario \(outcome.id): expected ruleId=\(outcome.expectedRuleId), observed=\(outcome.observedRuleId)")
        }
    }

    /// Schneier: every scenario, piped through `recordEgressDecision`,
    /// MUST land a deny row in `egress_decisions` and that row's
    /// `body_excerpt` MUST be post-redaction. The raw secret bytes from
    /// the planted-secret scenario MUST be absent from EVERY row written
    /// by the corpus.
    @Test("Schneier: every scenario writes a deny row with a REDACTED body excerpt — no raw secret leaks anywhere in the audit log")
    func everyScenarioWritesDenyRowWithRedactedExcerpt() {
        let path = Self.tempDBPath()
        defer { TempSessionDatabase.cleanup(path: path) }
        let db = SessionDatabase(path: path)
        defer { db.close() }

        let scenarios = MITMBodyInspectionCorpus.scenarios()
        #expect(scenarios.count == 8)

        for scenario in scenarios {
            let observed = scenario.observedRuleId()
            #expect(observed == scenario.expectedRuleId,
                    "scenario \(scenario.id) classification: \(observed) vs expected \(scenario.expectedRuleId)")
            #expect(db.recordEgressDecision(
                host: "api.example.com",
                method: "POST",
                decision: .deny,
                ruleId: observed,
                latencyUs: 1,
                paneMode: .general,
                judgeRationale: nil,
                bodyExcerpt: scenario.representativeBodyExcerpt.isEmpty
                    ? nil
                    : scenario.representativeBodyExcerpt
            ), "scenario \(scenario.id) deny row must persist")
        }

        let rows = db.recentEgressDecisions(limit: scenarios.count)
        #expect(rows.count == scenarios.count,
                "every scenario must produce exactly one deny row")
        for row in rows {
            #expect(row.decision == .deny,
                    "every scenario's row must be a deny (Schneier)")
        }
        let denyRuleIds = Set(rows.map { $0.ruleId })
        // Every expected ruleId must appear at least once across the
        // 8 rows (we have one row per scenario, so the set equals the
        // expected-ruleId set).
        let expectedRuleIds = Set(scenarios.map { $0.expectedRuleId })
        #expect(denyRuleIds == expectedRuleIds,
                "audit ruleIds (\(denyRuleIds)) must equal expected ruleIds (\(expectedRuleIds))")

        // Raw-secret invariant: the planted secret bytes MUST NOT
        // appear in ANY persisted body_excerpt anywhere in the corpus
        // (defense-in-depth — the redactor runs INSIDE prepareBodyExcerpt
        // so every scenario goes through it).
        let rawSecret = "sk-abcdef1234567890ABCDEFGHIJKL"
        for row in rows {
            guard let excerpt = row.bodyExcerpt,
                  let s = String(data: excerpt, encoding: .utf8) else { continue }
            #expect(!s.contains(rawSecret),
                    "Schneier P1: raw OPENAI key MUST NOT survive in any persisted body_excerpt (row id=\(row.id) rule=\(row.ruleId))")
        }
    }

    // MARK: - Per-scenario tests (8 individual cases)

    @Test("Scenario 1 — allowlisted host + body matcher denies SQL-injection payload")
    func scenario1_allowlistedHostDisallowedPayload() {
        let scenario = Self.scenario(id: "allowlisted-host-disallowed-payload")
        #expect(scenario.observedRuleId() == "body-deny-sql")
    }

    @Test("Scenario 2 — base64-encoded smuggling payload caught by bodyContains")
    func scenario2_base64Smuggling() {
        let scenario = Self.scenario(id: "base64-encoded-smuggling")
        #expect(scenario.observedRuleId() == "body-deny-base64-exfil")
    }

    @Test("Scenario 3 — MITM-inner Host header mismatches CONNECT-validated host (THE P0)")
    func scenario3_innerHostMismatch() {
        let scenario = Self.scenario(id: "inner-host-mismatch")
        #expect(scenario.observedRuleId() == "mitm_inner_host_mismatch")
    }

    @Test("Scenario 4 — MITM-inner request head exceeds 16 KB without terminator")
    func scenario4_oversizedHead() {
        let scenario = Self.scenario(id: "oversized-inner-head")
        #expect(scenario.observedRuleId() == "mitm_inner_head_too_large")
    }

    @Test("Scenario 5 — HTTP/2 client preface on MITM-terminated stream rejected as unknown protocol")
    func scenario5_http2Preface() {
        let scenario = Self.scenario(id: "http2-client-preface")
        #expect(scenario.observedRuleId() == "mitm_inner_unknown_protocol")
    }

    @Test("Scenario 6 — binary garbage on MITM-terminated stream rejected as unknown protocol")
    func scenario6_binaryGarbage() {
        let scenario = Self.scenario(id: "binary-garbage")
        #expect(scenario.observedRuleId() == "mitm_inner_unknown_protocol")
    }

    @Test("Scenario 7 — MITM-inner request missing Host header entirely (HTTP/1.1 requires Host)")
    func scenario7_missingHost() {
        let scenario = Self.scenario(id: "missing-host-header")
        // Karpathy r92 P2 — missing-Host is now distinct from
        // host-mismatch at the audit-row layer.
        #expect(scenario.observedRuleId() == "mitm_inner_no_host")
    }

    @Test("Scenario 8 — body planted secret redacted BEFORE judge/audit sees it (Schneier P1)")
    func scenario8_plantedSecretRedaction() {
        let scenario = Self.scenario(id: "planted-secret-redaction")
        #expect(scenario.observedRuleId() == "body-deny-secret-leak",
                "redaction must run BEFORE the body matcher sees it; observed=\(scenario.observedRuleId())")

        // Direct redaction-invariant assertion: the representative
        // excerpt MUST carry the SecretDetector marker and MUST NOT
        // carry the raw key. Schneier P1 — defense-in-depth.
        guard let s = String(data: scenario.representativeBodyExcerpt, encoding: .utf8) else {
            Issue.record("representative excerpt was not UTF-8")
            return
        }
        let raw = "sk-abcdef1234567890ABCDEFGHIJKL"
        #expect(!s.contains(raw),
                "Schneier P1: raw key must NOT appear in representative redacted excerpt")
        #expect(s.contains("[REDACTED:"),
                "SecretDetector marker must appear post-redaction")
    }

    // MARK: - Helpers

    /// r89 P3 (Lauret) — GemmaJudgeAdapter prompt body-excerpt framing
    /// snapshot. Pins the EXACT framing string so a future tweak (e.g.
    /// renaming `"Request body excerpt"` to `"Body excerpt:"`) breaks
    /// THIS test rather than slipping through the loose
    /// `contains("Request body excerpt")` substring assertion in
    /// EgressBodyExcerptTests.
    @Test("r89 P3 — GemmaJudgeAdapter prompt body-excerpt framing prefix snapshot")
    func gemmaPromptBodyExcerptFramingSnapshot() {
        let body = Data("{\"k\":\"v\"}".utf8)
        let request = JudgeRequest(
            host: "api.example.com",
            method: "POST",
            paneMode: .general,
            bodyExcerpt: body
        )
        let prompt = GemmaJudgeAdapter.buildPrompt(request)
        #expect(prompt.contains(GemmaJudgeAdapter.bodyExcerptFramingPrefix),
                "framing prefix code-constant must appear in the rendered prompt")
        #expect(GemmaJudgeAdapter.bodyExcerptFramingPrefix
                    == "Request body excerpt (≤4 KB, post-redaction):",
                "framing prefix constant snapshot pinned — changing this needs the prompt + LLM expectations updated in lockstep")

        // The framing prefix must be followed by a newline + the body
        // bytes (the structured-section shape).
        let needle = "\n\n\(GemmaJudgeAdapter.bodyExcerptFramingPrefix)\n{\"k\":\"v\"}"
        #expect(prompt.contains(needle),
                "the rendered prompt section must follow the framing prefix with a newline + the body bytes")
    }

    /// r89 P3 (Karpathy) — NULL-vs-EMPTY body excerpt policy pin.
    /// `.none` and `.some(Data())` produce DISTINCT canonical hashes
    /// (one writes `.null`, the other writes `.blob(Data())`). They are
    /// different events at the audit layer by design; this test pins
    /// that property so a future refactor that collapses the two into
    /// one canonical-map cell breaks visibly.
    @Test("r89 P3 — NULL body excerpt and EMPTY body excerpt produce distinct canonical hashes (policy pin)")
    func nullVsEmptyBodyExcerptDistinctHashes() {
        let path = Self.tempDBPath()
        defer { TempSessionDatabase.cleanup(path: path) }
        let db = SessionDatabase(path: path)
        defer { db.close() }

        // Same shape, different body excerpt — one nil, one empty Data.
        #expect(db.recordEgressDecision(
            host: "api.example.com", method: "POST",
            decision: .deny, ruleId: "nil-body",
            latencyUs: 1, paneMode: .general,
            judgeRationale: nil, bodyExcerpt: nil))

        #expect(db.recordEgressDecision(
            host: "api.example.com", method: "POST",
            decision: .deny, ruleId: "empty-body",
            latencyUs: 1, paneMode: .general,
            judgeRationale: nil, bodyExcerpt: Data()))

        // Both rows must verify (which proves the canonical-map hash
        // re-derived identically for each on its own row).
        switch ChainVerifier.verifyEgressDecisions(db) {
        case .ok: break
        case .brokenAt(let table, let rowid, let exp, let act):
            Issue.record("expected .ok, got brokenAt \(table):\(rowid) expected=\(exp) actual=\(act)")
        case .noChain:
            Issue.record("expected .ok, got .noChain")
        }

        let rows = db.recentEgressDecisions(limit: 2)
        #expect(rows.count == 2)
        // The two rows have DIFFERENT body_excerpt slots — one nil,
        // one empty Data. This proves the on-disk distinction is
        // preserved across the write/read round-trip.
        let bodyValues = Set(rows.map { row -> String in
            if let b = row.bodyExcerpt { return "blob(\(b.count))" }
            return "null"
        })
        #expect(bodyValues.contains("null"),
                "nil bodyExcerpt must persist as NULL distinguishable from empty blob")
        #expect(bodyValues.contains("blob(0)"),
                "empty Data() bodyExcerpt must persist as an empty blob distinct from NULL")
    }

    private static func scenario(id: String) -> MITMBodyInspectionCorpus.Scenario {
        let all = MITMBodyInspectionCorpus.scenarios()
        guard let match = all.first(where: { $0.id == id }) else {
            preconditionFailure("scenario \(id) missing from corpus")
        }
        return match
    }

    // MARK: - t1d-5 follow-ups Round A — CONNECT-path body excerpt plumbing

    /// t1d-5 follow-ups Round A — the CONNECT-path body-excerpt corpus
    /// extends `scenarios()` with two scenarios that exercise the new
    /// plumbing from `MITMUpstreamVerify.pipeBidirectional`'s
    /// `onInnerBodyExcerpt` callback through to
    /// `recordEgressDecision`'s `bodyExcerpt:` slot. The 8-scenario
    /// activation-gate corpus stays FROZEN — these scenarios live in
    /// `MITMBodyInspectionCorpus.connectPathScenarios()`.
    @Test("t1d-5 follow-ups Round A — CONNECT-path body-deny scenarios classify + redact correctly")
    func connectPathScenariosClassifyCorrectly() {
        let scenarios = MITMBodyInspectionCorpus.connectPathScenarios()
        #expect(scenarios.count == 2,
                "CONNECT-path corpus must carry exactly 2 scenarios (body-deny-fires + planted-secret-redacted)")
        for scenario in scenarios {
            let observed = scenario.observedRuleId()
            #expect(observed == scenario.expectedRuleId,
                    "CONNECT-path scenario \(scenario.id): expected ruleId=\(scenario.expectedRuleId), observed=\(observed)")
        }
    }

    /// Schneier P1 end-to-end on the CONNECT path: a planted-secret body
    /// in a CONNECT-tunneled request must have the raw secret REPLACED in
    /// the persisted `body_excerpt` BEFORE any hashing / SQLite bind.
    /// This locks in the truncate-then-redact-before-hash invariant on the
    /// CONNECT path (the same invariant the non-CONNECT path already
    /// exercised via scenario 8 of the activation-gate corpus).
    @Test("t1d-5 follow-ups Round A — Schneier P1 CONNECT-path planted-secret redaction: raw secret never lands on disk")
    func connectPathPlantedSecretRedactedBeforeAudit() {
        let path = Self.tempDBPath()
        defer { TempSessionDatabase.cleanup(path: path) }
        let db = SessionDatabase(path: path)
        defer { db.close() }

        // Karpathy P1 fix: pass the RAW planted-secret body bytes (NOT
        // the corpus's already-`prepareBodyExcerpt`-redacted
        // `representativeBodyExcerpt`) so the store's
        // `prepareBodyExcerpt` is the ONLY redaction barrier under
        // test. With the prior wiring the input was double-redacted —
        // the "no raw secret on disk" assertion passed trivially
        // because the test input never CONTAINED the raw secret in the
        // first place. Now the test input DOES contain the raw secret
        // and the assertion meaningfully proves the store redacted
        // before persisting.
        let rawSecret = "sk-abcdef1234567890ABCDEFGHIJKL"
        guard let rawPlantedSecretBody = MITMUpstreamVerify.innerBodyBytes(
            fromHeadBuffer: MITMBodyInspectionCorpus.connectInnerBodyPlantedSecretHead
        ) else {
            Issue.record("planted-secret raw body fixture must extract a non-nil body slice")
            return
        }
        // Sanity-check the fixture before the round-trip: the RAW body
        // slice MUST carry the raw secret bytes (otherwise the
        // assertion below would be vacuous in a different way).
        guard let rawBodyStr = String(data: rawPlantedSecretBody, encoding: .utf8) else {
            Issue.record("planted-secret raw body must be UTF-8 decodable")
            return
        }
        #expect(rawBodyStr.contains(rawSecret),
                "fixture invariant: the RAW planted-secret body slice MUST contain the raw secret bytes (otherwise the redaction-before-persist assertion is vacuous)")

        // Also derive the matching raw body for the body-deny scenario
        // so both rows go in with raw (non-double-redacted) bytes.
        guard let rawDenyBody = MITMUpstreamVerify.innerBodyBytes(
            fromHeadBuffer: MITMBodyInspectionCorpus.connectInnerBodyDenyHead
        ) else {
            Issue.record("body-deny raw body fixture must extract a non-nil body slice")
            return
        }

        // Insert one row per scenario, keyed off scenario id to pick
        // the matching RAW body bytes. The store's `prepareBodyExcerpt`
        // is the only redaction barrier between these raw bytes and
        // disk.
        let scenarios = MITMBodyInspectionCorpus.connectPathScenarios()
        for scenario in scenarios {
            let rawBody: Data
            switch scenario.id {
            case "connect-path-body-planted-secret-redacted":
                rawBody = rawPlantedSecretBody
            case "connect-path-body-deny-fires":
                rawBody = rawDenyBody
            default:
                Issue.record("unexpected CONNECT-path scenario id: \(scenario.id)")
                return
            }
            #expect(db.recordEgressDecision(
                host: "api.example.com",
                method: "POST",
                decision: .deny,
                ruleId: scenario.expectedRuleId,
                latencyUs: 1,
                paneMode: .general,
                judgeRationale: nil,
                bodyExcerpt: rawBody
            ), "CONNECT-path scenario \(scenario.id) deny row must persist")
        }

        let rows = db.recentEgressDecisions(limit: scenarios.count)
        #expect(rows.count == scenarios.count)

        // Schneier P1 — raw OPENAI key bytes MUST NOT appear in any
        // persisted CONNECT-path body_excerpt. With raw inputs now
        // carrying the raw secret on the way in, this is the
        // load-bearing assertion: failure means the store's redaction
        // barrier did NOT run before the SQLite bind.
        for row in rows {
            guard let excerpt = row.bodyExcerpt,
                  let s = String(data: excerpt, encoding: .utf8) else { continue }
            #expect(!s.contains(rawSecret),
                    "Schneier P1: raw OPENAI key MUST NOT survive in any persisted CONNECT-path body_excerpt (row id=\(row.id) rule=\(row.ruleId))")
        }

        // Positive assertion: at least one persisted CONNECT-path row
        // must carry the SecretDetector marker, proving the redaction
        // ran (and ran BEFORE the row landed on disk).
        let redactedRows = rows.compactMap { row -> String? in
            guard let excerpt = row.bodyExcerpt,
                  let s = String(data: excerpt, encoding: .utf8),
                  s.contains("[REDACTED:") else { return nil }
            return s
        }
        #expect(!redactedRows.isEmpty,
                "at least one CONNECT-path row must carry the SecretDetector marker post-redaction")

        // Karpathy P1 fix (additional assertion) — the canonical body
        // bytes that landed on disk MUST equal what `prepareBodyExcerpt`
        // produces over the RAW input. Because the chain `entry_hash`
        // (EgressDecisionStore.swift line ~170) is computed over the
        // canonical column map which includes `body_excerpt` on v46+
        // anchors, equal on-disk bytes imply equal hash inputs — i.e.
        // the chain hash is bound to the REDACTED form, never the raw
        // form. (Row does not expose entry_hash directly; comparing
        // the persisted bytes to the redacted form is the cleanest
        // proxy without widening the public API.)
        let expectedRedactedPlanted = EgressDecisionStore.prepareBodyExcerpt(rawPlantedSecretBody)
        let expectedRedactedDeny = EgressDecisionStore.prepareBodyExcerpt(rawDenyBody)
        for row in rows {
            switch row.ruleId {
            case "connect-body-deny-secret-leak":
                #expect(row.bodyExcerpt == expectedRedactedPlanted,
                        "persisted body_excerpt MUST equal prepareBodyExcerpt(raw) — the canonical bytes hashed into the chain are the REDACTED form, not the raw form")
            case "connect-body-deny-sql":
                #expect(row.bodyExcerpt == expectedRedactedDeny,
                        "persisted body_excerpt MUST equal prepareBodyExcerpt(raw) — the canonical bytes hashed into the chain are the REDACTED form, not the raw form")
            default:
                Issue.record("unexpected persisted ruleId on CONNECT-path row: \(row.ruleId)")
            }
        }
    }

    /// Pin the byte-shape `MITMUpstreamVerify.innerBodyBytes(fromHeadBuffer:)`
    /// returns so a regression on the head/body slice boundary breaks
    /// THIS test rather than silently leaking the request HEAD into the
    /// body excerpt slot (which would be a Schneier-flagged info-leak
    /// into the audit row).
    @Test("t1d-5 follow-ups Round A — innerBodyBytes slices ONLY the post-CRLFCRLF bytes from the rebind head buffer")
    func innerBodyBytesSlicesPostTerminatorOnly() {
        // HEAD + body buffer (decrypted plaintext as it would appear in
        // the rebind peek's `.allow(headBytes:)` payload).
        let head = "POST /v1/exec HTTP/1.1\r\nHost: api.example.com\r\n\r\n"
        let body = "{\"command\":\"DROP TABLE users; --\"}"
        let combined = Array((head + body).utf8)
        guard let extracted = MITMUpstreamVerify.innerBodyBytes(fromHeadBuffer: combined) else {
            Issue.record("innerBodyBytes must extract a non-nil body from the head+body buffer")
            return
        }
        #expect(extracted == Data(body.utf8),
                "extracted body must equal the post-CRLFCRLF slice byte-for-byte")
        let extractedStr = String(data: extracted, encoding: .utf8) ?? ""
        // Defense-in-depth: the HEAD must NEVER appear inside the body
        // excerpt slot (otherwise the audit row would carry the request
        // method + path, which is an info-leak surface we already audit
        // through `host` + `method` columns).
        #expect(!extractedStr.contains("POST /v1/exec"),
                "the request HEAD must NEVER leak into the extracted body excerpt")
        #expect(!extractedStr.contains("Host: api.example.com"),
                "the Host header must NEVER leak into the extracted body excerpt")

        // No-body request — HEAD only, no trailing bytes.
        let headOnly = Array("GET /v1/test HTTP/1.1\r\nHost: api.example.com\r\n\r\n".utf8)
        #expect(MITMUpstreamVerify.innerBodyBytes(fromHeadBuffer: headOnly) == nil,
                "HEAD-only buffer (no trailing body bytes) must return nil")
    }

    /// r98 t1d-5 r52 Karpathy P2 — `Content-Length: 0` POST.
    /// Explicit empty-body POST request: the HEAD declares CL:0 and the
    /// buffer terminates at `\r\n\r\n` with NO trailing bytes. Matches
    /// the helper's `body.isEmpty ? nil` defensive return — callers
    /// downstream see `nil` and skip emitting an empty-blob audit row.
    @Test("t1d-5 r52 Karpathy P2 — Content-Length: 0 POST → innerBodyBytes returns nil (no empty-blob audit row)")
    func innerBodyBytesContentLengthZeroReturnsNil() {
        let head = "POST /v1/exec HTTP/1.1\r\nHost: api.example.com\r\nContent-Length: 0\r\n\r\n"
        let buf = Array(head.utf8)
        // The CRLFCRLF terminator sits at the very END of the buffer;
        // there are zero trailing bytes. `terminatorEnd == headBytes.count`
        // so the `end < headBytes.count` guard fires and the helper
        // returns nil (the same defensive branch covered by the existing
        // HEAD-only assertion, but explicitly pinned for the CL:0 case
        // an operator audit-grep would encounter).
        #expect(MITMUpstreamVerify.innerBodyBytes(fromHeadBuffer: buf) == nil,
                "Content-Length:0 POST (HEAD ends at CRLFCRLF, zero body bytes) must return nil")
    }

    /// r98 t1d-5 r52 Karpathy P2 — malformed HEAD with NO `\r\n\r\n`
    /// terminator. The rebind peek's contract is "only return `.allow`
    /// once a terminator is found", so this branch is defensively
    /// unreachable in practice — but the helper's guard MUST hold so a
    /// future refactor of `peekAndDecide` cannot leak a partial HEAD as
    /// the body excerpt.
    @Test("t1d-5 r52 Karpathy P2 — malformed HEAD (no CRLFCRLF) → innerBodyBytes returns nil (helper contract pin)")
    func innerBodyBytesMalformedHeadReturnsNil() {
        // 16 KiB buffer with NO `\r\n\r\n` terminator — mimics the
        // `peekAndDecide` over-budget branch's input shape, but fed
        // straight to the helper to pin its `guard terminatorEnd` early
        // return. Bytes are valid ASCII so the failure mode is
        // unambiguously "no terminator" not "non-UTF8".
        let payload = String(repeating: "A", count: 16 * 1024)
        let buf = Array(payload.utf8)
        #expect(buf.count == 16 * 1024)
        #expect(MITMUpstreamVerify.innerBodyBytes(fromHeadBuffer: buf) == nil,
                "16 KiB buffer with no CRLFCRLF terminator must return nil (no partial-HEAD leak)")
    }

    /// r98 t1d-5 r52 Karpathy P2 — straddle-boundary: body slice contains
    /// a secret-shape token. `innerBodyBytes` is a PURE slice — it does
    /// not redact. The Schneier P1 truncate-then-redact-before-hash
    /// invariant lives downstream in `EgressDecisionStore.prepareBodyExcerpt`.
    /// This test composes the two and asserts the integrated invariant:
    /// the visible portion of a partially-captured token is REDACTED
    /// before it can land in the audit row or the engine's bodyExcerpt.
    @Test("t1d-5 r52 Karpathy P2 — straddle-boundary: secret in partial body slice is REDACTED by prepareBodyExcerpt before the engine sees it")
    func innerBodyBytesStraddleBoundaryScrubsVisiblePortion() {
        // Construct a HEAD + body such that the body contains a fully-
        // formed sk-ant-* shaped token. innerBodyBytes slices the body
        // verbatim; prepareBodyExcerpt then runs SecretDetector
        // redaction. Assert the integrated output does NOT carry the
        // raw token.
        let head = "POST /v1/messages HTTP/1.1\r\nHost: api.anthropic.com\r\n\r\n"
        let plantedSecret = "sk-ant-abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let body = "{\"prompt\":\"\(plantedSecret)\",\"max_tokens\":10}"
        let buf = Array((head + body).utf8)

        guard let raw = MITMUpstreamVerify.innerBodyBytes(fromHeadBuffer: buf) else {
            Issue.record("innerBodyBytes must extract a non-nil body slice")
            return
        }
        // Helper is a pure slice — raw bytes contain the planted secret.
        // This is BY DESIGN: redaction happens at prepareBodyExcerpt,
        // not at the slice boundary. The lock-in here is "the SLICE +
        // REDACT integration holds end-to-end on the CONNECT path."
        #expect(String(data: raw, encoding: .utf8)?.contains(plantedSecret) == true,
                "innerBodyBytes is a pure slice — the raw body slice contains the planted secret pre-redaction")

        let redacted = EgressDecisionStore.prepareBodyExcerpt(raw)
        let redactedStr = String(data: redacted, encoding: .utf8) ?? ""
        #expect(!redactedStr.contains(plantedSecret),
                "after prepareBodyExcerpt the planted sk-ant-* token must NOT survive — Schneier P1 invariant")
    }
}

/// T.1d-5 — extension of `senkani doctor --check-egress` reporting.
/// Pin the operator-greppable surface so a future tweak to the format
/// shows up in PR review. Both helpers live in `Core.MITMBodyInspectionCorpus`
/// so the CLI module never names `EgressDecisionStore.Row` directly
/// (preserves the egress-write API deny-list).
@Suite("T.1d-5 — doctor --check-egress MITM state + corpus pass-rate + recent denials")
struct DoctorCheckEgressMITMStateTests {

    /// Flag ON + CA on disk + 8/8 corpus pass + a couple of recent
    /// denials → 3 lines in operator-greppable form.
    @Test("doctor --check-egress: ON + ca + 8/8 + denials renders the expected three lines")
    func flagOnCaOnDiskFullGreenWithDenials() {
        let lines = MITMBodyInspectionCorpus.formatCheckEgressMITMStateLines(
            flagOn: true,
            caOnDisk: true,
            bodyCorpusPassed: 8,
            bodyCorpusTotal: 8,
            recentDenialCounts: [
                (ruleId: "mitm_inner_host_mismatch", count: 3),
                (ruleId: "body-deny-sql", count: 2),
            ]
        )
        #expect(lines.count == 4)
        #expect(lines[0] == "mitm: enabled | ca-on-disk: yes",
                "mitm state line shape pinned (operator-greppable)")
        #expect(lines[1] == "body-inspection corpus: 8/8",
                "corpus pass-rate line shape pinned (operator-greppable)")
        #expect(lines[2].hasPrefix("recent denials (last 200): "),
                "denials line carries the stable prefix")
        // Highest count rendered first; ties sort alphabetically.
        #expect(lines[2].contains("mitm_inner_host_mismatch=3"))
        #expect(lines[2].contains("body-deny-sql=2"))
        // T.1d-3 — best-effort caveat footer (operator caveat surface).
        #expect(lines[3].hasPrefix("note: body/header/path DENY rules are best-effort"),
                "caveat footer line carries the stable prefix")
        #expect(lines[3].contains("docs/concepts/security-posture.html"),
                "caveat footer references the operator-facing doc surface")
    }

    /// Flag OFF surface (also covers the back-compat "disabled" word).
    @Test("doctor --check-egress: flag OFF renders 'disabled'")
    func flagOffRendersDisabled() {
        let lines = MITMBodyInspectionCorpus.formatCheckEgressMITMStateLines(
            flagOn: false,
            caOnDisk: false,
            bodyCorpusPassed: 8,
            bodyCorpusTotal: 8,
            recentDenialCounts: []
        )
        #expect(lines[0] == "mitm: disabled | ca-on-disk: no")
        #expect(lines[2] == "recent denials (last 200): none",
                "empty denial set renders 'none' rather than an empty string")
    }

    /// Failure case — corpus partial pass renders the partial fraction.
    @Test("doctor --check-egress: partial corpus pass-rate (7/8) is rendered as 7/8 not 'failed'")
    func partialCorpusRenders() {
        let lines = MITMBodyInspectionCorpus.formatCheckEgressMITMStateLines(
            flagOn: true,
            caOnDisk: true,
            bodyCorpusPassed: 7,
            bodyCorpusTotal: 8,
            recentDenialCounts: []
        )
        #expect(lines[1] == "body-inspection corpus: 7/8")
    }

    /// r99 t1d-5 r52 Karpathy P2 — connect-path corpus suffix appears
    /// when `connectPathTotal > 0`. Back-compat: `connectPathTotal == 0`
    /// (the default) renders the SAME line shape as pre-r99 callers, so
    /// existing tests continue to pass byte-identically.
    @Test("doctor --check-egress: connect-path corpus suffix appears when connectPathTotal > 0")
    func connectPathSuffixAppears() {
        let lines = MITMBodyInspectionCorpus.formatCheckEgressMITMStateLines(
            flagOn: true,
            caOnDisk: true,
            bodyCorpusPassed: 8,
            bodyCorpusTotal: 8,
            recentDenialCounts: [],
            connectPathPassed: 2,
            connectPathTotal: 2
        )
        #expect(lines[1] == "body-inspection corpus: 8/8 + connect-path: 2/2",
                "corpus line suffixed with connect-path pass-rate when connectPathTotal > 0")
        // Suffix MUST land on the same line, not a new one — line count
        // stays at 4 (mitm-state, corpus, denials, caveat-footer).
        #expect(lines.count == 4,
                "suffix sits on the existing corpus line; does not add a new line")
    }

    /// r99 t1d-5 r52 Karpathy P2 — back-compat: default-arg form
    /// (no connect-path args) renders the byte-identical pre-r99 shape.
    /// Lock-in so a future refactor cannot accidentally flip the default
    /// to emit a `+ connect-path: 0/0` empty suffix.
    @Test("doctor --check-egress: connect-path suffix omitted when connectPathTotal == 0 (back-compat default)")
    func connectPathSuffixOmittedByDefault() {
        let lines = MITMBodyInspectionCorpus.formatCheckEgressMITMStateLines(
            flagOn: true,
            caOnDisk: true,
            bodyCorpusPassed: 8,
            bodyCorpusTotal: 8,
            recentDenialCounts: []
        )
        #expect(lines[1] == "body-inspection corpus: 8/8",
                "default-arg form (no connect-path args) renders pre-r99 line shape byte-identical")
        #expect(!lines[1].contains("connect-path"),
                "default-arg form must NOT emit '+ connect-path: 0/0' empty suffix")
    }

    /// r99 t1d-5 r52 Karpathy P2 — `runConnectPath()` actually returns
    /// outcomes for `connectPathScenarios()` (lock the orphan fix).
    @Test("r99 — runConnectPath() returns outcomes for connectPathScenarios (not the frozen 8)")
    func runConnectPathSweepsConnectPathScenarios() {
        let connectResult = MITMBodyInspectionCorpus.runConnectPath()
        let connectScenarios = MITMBodyInspectionCorpus.connectPathScenarios()
        #expect(connectResult.outcomes.count == connectScenarios.count,
                "runConnectPath() iterates connectPathScenarios() exactly once")
        #expect(connectResult.outcomes.count > 0,
                "runConnectPath() must return AT LEAST the existing CONNECT-path scenarios — guards against future accidental drop")
        // The activation-gate `run()` returns the FROZEN 8-scenario set
        // and MUST NOT have been disturbed by adding the new sweep.
        let frozenResult = MITMBodyInspectionCorpus.run()
        #expect(frozenResult.outcomes.count == 8,
                "scenarios() corpus stays FROZEN at 8 — adding runConnectPath() does not perturb the activation gate")
    }

    /// T.1d-3 — the best-effort caveat footer is unconditional. Operator
    /// must see the caveat whether MITM is on or off, whether the corpus
    /// is all-green or partial, and whether there are recent denials or
    /// none. The footer points at the operator-facing doc surface so the
    /// evasion-vector list lives at exactly one source of truth.
    @Test("doctor --check-egress: best-effort caveat footer is unconditional + references the docs")
    func caveatFooterIsUnconditional() {
        // Variant A — flag OFF, no CA, all-green corpus, no denials.
        let offLines = MITMBodyInspectionCorpus.formatCheckEgressMITMStateLines(
            flagOn: false,
            caOnDisk: false,
            bodyCorpusPassed: 8,
            bodyCorpusTotal: 8,
            recentDenialCounts: []
        )
        #expect(offLines.count == 4, "caveat footer present even when flag is off")
        #expect(offLines.last?.hasPrefix("note: ") == true,
                "footer carries the stable 'note:' prefix")
        #expect(offLines.last?.contains("best-effort defense-in-depth") == true,
                "footer names the best-effort defense-in-depth posture")
        #expect(offLines.last?.contains("docs/concepts/security-posture.html") == true,
                "footer points at the operator-facing doc surface (single source of truth)")

        // Variant B — flag ON, CA present, partial corpus, with denials.
        let onLines = MITMBodyInspectionCorpus.formatCheckEgressMITMStateLines(
            flagOn: true,
            caOnDisk: true,
            bodyCorpusPassed: 7,
            bodyCorpusTotal: 8,
            recentDenialCounts: [(ruleId: "body-deny-sql", count: 1)]
        )
        #expect(onLines.count == 4, "caveat footer present in the full-on state too")
        #expect(onLines.last == offLines.last,
                "footer text is identical across states — it's a stable caveat, not state-conditional")
    }

    /// r93 Allspaw P3 — install-CA hint appears ONLY in the flag-on +
    /// no-CA state. An operator who ran `--check-egress` (without the
    /// broader `doctor` run) previously saw `mitm: enabled | ca-on-disk:
    /// no` with no prescription — the hint surfaces the fix at the same
    /// site as the diagnosis. The hint is absent in flag-off / on-with-CA
    /// states. The caveat footer remains the LAST line in ALL states.
    @Test("r93 Allspaw P3 — install-CA hint present ONLY when flag-on + ca-on-disk false; caveat remains last")
    func installCAHintConditionalOnFlagOnNoCA() {
        // Variant A — flag ON + CA missing → 5 lines, hint at index 3,
        // caveat at index 4.
        let onNoCa = MITMBodyInspectionCorpus.formatCheckEgressMITMStateLines(
            flagOn: true,
            caOnDisk: false,
            bodyCorpusPassed: 8,
            bodyCorpusTotal: 8,
            recentDenialCounts: []
        )
        #expect(onNoCa.count == 5,
                "flag-on + no-CA renders 5 lines (mitm/corpus/denials/hint/caveat)")
        #expect(onNoCa[0] == "mitm: enabled | ca-on-disk: no")
        #expect(onNoCa[3].hasPrefix("hint: run `senkani doctor --install-egress-ca`"),
                "hint line is positioned just before the caveat footer")
        #expect(onNoCa[3].contains("MITM termination"),
                "hint surfaces the prescription tied to MITM termination")
        // Caveat MUST remain the last line in this 5-line variant.
        #expect(onNoCa.last?.hasPrefix("note: ") == true,
                "caveat footer remains the LAST line even when the hint is present")

        // Variant B — flag ON + CA present → NO hint, 4 lines.
        let onWithCa = MITMBodyInspectionCorpus.formatCheckEgressMITMStateLines(
            flagOn: true,
            caOnDisk: true,
            bodyCorpusPassed: 8,
            bodyCorpusTotal: 8,
            recentDenialCounts: []
        )
        #expect(onWithCa.count == 4,
                "flag-on + ca-on-disk renders 4 lines (no hint needed)")
        #expect(!onWithCa.contains(where: { $0.hasPrefix("hint: ") }),
                "no install-CA hint when the CA is already on disk")

        // Variant C — flag OFF (with or without CA) → NO hint, 4 lines.
        let offNoCa = MITMBodyInspectionCorpus.formatCheckEgressMITMStateLines(
            flagOn: false,
            caOnDisk: false,
            bodyCorpusPassed: 8,
            bodyCorpusTotal: 8,
            recentDenialCounts: []
        )
        #expect(offNoCa.count == 4,
                "flag-off renders 4 lines (no hint — operator hasn't asked for MITM)")
        #expect(!offNoCa.contains(where: { $0.hasPrefix("hint: ") }),
                "no install-CA hint when the MITM flag is off")

        let offWithCa = MITMBodyInspectionCorpus.formatCheckEgressMITMStateLines(
            flagOn: false,
            caOnDisk: true,
            bodyCorpusPassed: 8,
            bodyCorpusTotal: 8,
            recentDenialCounts: []
        )
        #expect(offWithCa.count == 4,
                "flag-off + ca-on-disk renders 4 lines (no hint)")
        #expect(!offWithCa.contains(where: { $0.hasPrefix("hint: ") }))
    }

    /// `countDenialsByRuleId` — verify the grouping function deterministically
    /// sorts by (descending count, then ascending ruleId) so the operator
    /// surface is stable across runs.
    @Test("countDenialsByRuleId groups + sorts by (count desc, ruleId asc) deterministically")
    func countDenialsGroupsAndSorts() {
        let rows: [EgressDecisionStore.Row] = [
            sampleRow(id: 1, ruleId: "mitm_inner_host_mismatch", decision: .deny),
            sampleRow(id: 2, ruleId: "mitm_inner_host_mismatch", decision: .deny),
            sampleRow(id: 3, ruleId: "mitm_inner_head_too_large", decision: .deny),
            sampleRow(id: 4, ruleId: "body-deny-sql", decision: .deny),
            sampleRow(id: 5, ruleId: "body-deny-sql", decision: .deny),
            sampleRow(id: 6, ruleId: "should-skip", decision: .allow),  // not deny
        ]
        let grouped = MITMBodyInspectionCorpus.countDenialsByRuleId(rows)
        // Counts: mitm_inner_host_mismatch=2, body-deny-sql=2, mitm_inner_head_too_large=1
        #expect(grouped.count == 3, "allow row must be filtered out")
        // First two share count 2; alphabetical tie-break: body-* < mitm-*.
        #expect(grouped[0].ruleId == "body-deny-sql")
        #expect(grouped[0].count == 2)
        #expect(grouped[1].ruleId == "mitm_inner_host_mismatch")
        #expect(grouped[1].count == 2)
        #expect(grouped[2].ruleId == "mitm_inner_head_too_large")
        #expect(grouped[2].count == 1)
    }

    private func sampleRow(
        id: Int64, ruleId: String, decision: EgressRule.Decision
    ) -> EgressDecisionStore.Row {
        EgressDecisionStore.Row(
            id: id, timestamp: Date(),
            host: "api.example.com", method: "POST",
            decision: decision, ruleId: ruleId,
            latencyUs: 1, paneId: nil, projectRoot: nil,
            paneMode: nil, judgeRationale: nil, bodyExcerpt: nil
        )
    }
}
