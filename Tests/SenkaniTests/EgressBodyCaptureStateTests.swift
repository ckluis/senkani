import Testing
import Foundation
import SQLite3
@testable import Core

/// T.1d-5 r52 Allspaw P2 (v47) — capture-state annotation on the egress
/// audit row. Before v47 a row with `body_excerpt: nil` was AMBIGUOUS:
/// no body sent vs body overflowed the 16 KB peek window vs extraction
/// failed. The `body_excerpt_capture_state` column disambiguates so
/// doctor `--check-egress` can surface a per-state counter and an
/// operator can spot an `.overflowed` spike.
///
/// FOURTH canonical-shape tier for `egress_decisions`. The load-bearing
/// integrity invariant (Schneier P0): `migration-v46` rows were hashed
/// under the v46 shape (body_excerpt but NO capture_state) and MUST stay
/// v46-shape forever — the v47 exclusion list in both
/// `ChainVerifier.verifyAnchorEgressDecisions` and the writer's
/// `useV47Shape` predicate keeps them out of the v47 tier so their
/// entry_hash bytes remain re-derivable post-v47 migration.
///
/// Tests are `.serialized` because they each construct a temp
/// SessionDatabase that runs the full migration array. Mirrors
/// `EgressBodyExcerptTests`.
@Suite("Egress body capture-state — v47 annotation + canonical-shape tier", .serialized)
struct EgressBodyCaptureStateTests {

    private static func tempDBPath() -> String {
        let dir = NSTemporaryDirectory() + "senkani-t1d5-capture-state-tests/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "egress-decisions-v47-\(UUID().uuidString).db"
    }

    private static func anchorCount(path: String, reason: String) -> Int {
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else { return -1 }
        defer { sqlite3_close(handle) }
        let sql = """
            SELECT COUNT(*) FROM chain_anchors
             WHERE table_name = 'egress_decisions' AND reason = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (reason as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func columnNames(path: String) -> [String] {
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else { return [] }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(egress_decisions);", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) {
                out.append(String(cString: c))
            }
        }
        return out
    }

    /// Build a raw head buffer: a request line + headers + `\r\n\r\n` +
    /// optional body bytes. Mirrors what the rebind peek's `.allow` arm
    /// hands to `innerBodyCaptureState`.
    private static func headBuffer(
        requestLine: String = "POST /v1/chat HTTP/1.1",
        headers: [String] = ["Host: api.example.com"],
        bodyBytes: [UInt8] = []
    ) -> [UInt8] {
        var s = requestLine + "\r\n"
        for h in headers { s += h + "\r\n" }
        s += "\r\n"
        var out = Array(s.utf8)
        out.append(contentsOf: bodyBytes)
        return out
    }

    // MARK: - 1. Pure classifier — all four states

    @Test("innerBodyCaptureState: terminator + body bytes, no/fitting Content-Length → .captured")
    func classifierCaptured() {
        // Body present, no Content-Length to compare → .captured.
        let buf = Self.headBuffer(bodyBytes: Array("{\"x\":1}".utf8))
        #expect(MITMUpstreamVerify.innerBodyCaptureState(fromHeadBuffer: buf) == .captured)

        // Body present, Content-Length declares EXACTLY what's captured →
        // .captured (declared not greater than captured).
        let body = Array("{\"x\":1}".utf8)
        let bufCL = Self.headBuffer(
            headers: ["Host: api.example.com", "Content-Length: \(body.count)"],
            bodyBytes: body)
        #expect(MITMUpstreamVerify.innerBodyCaptureState(fromHeadBuffer: bufCL) == .captured)
    }

    @Test("innerBodyCaptureState: terminator + zero body bytes → .empty")
    func classifierEmpty() {
        // GET-style: HEAD terminates, no body follows.
        let buf = Self.headBuffer(
            requestLine: "GET / HTTP/1.1",
            headers: ["Host: api.example.com"],
            bodyBytes: [])
        #expect(MITMUpstreamVerify.innerBodyCaptureState(fromHeadBuffer: buf) == .empty)

        // Explicit Content-Length: 0 POST — terminator, no body.
        let bufCL0 = Self.headBuffer(
            headers: ["Host: api.example.com", "Content-Length: 0"],
            bodyBytes: [])
        #expect(MITMUpstreamVerify.innerBodyCaptureState(fromHeadBuffer: bufCL0) == .empty)
    }

    @Test("innerBodyCaptureState: Content-Length declares MORE than captured → .overflowed")
    func classifierOverflowed() {
        // 8 captured body bytes but Content-Length says 100_000 → the body
        // overflowed the peek window; captured slice is a prefix.
        let body = Array("12345678".utf8)
        let buf = Self.headBuffer(
            headers: ["Host: api.example.com", "Content-Length: 100000"],
            bodyBytes: body)
        #expect(MITMUpstreamVerify.innerBodyCaptureState(fromHeadBuffer: buf) == .overflowed)
    }

    @Test("innerBodyCaptureState: no \\r\\n\\r\\n terminator / tiny buffer → .extractionFailed")
    func classifierExtractionFailed() {
        // No terminator at all (defensively unreachable from .allow, but
        // the classifier must be honest).
        let noTerm = Array("POST /v1/chat HTTP/1.1\r\nHost: api.example.com\r\n".utf8)
        #expect(MITMUpstreamVerify.innerBodyCaptureState(fromHeadBuffer: noTerm) == .extractionFailed)

        // Fewer than 4 bytes → .extractionFailed.
        #expect(MITMUpstreamVerify.innerBodyCaptureState(fromHeadBuffer: [0x0d]) == .extractionFailed)
    }

    @Test("innerBodyCaptureState: chunked body (no Content-Length) reports .captured, never false .overflowed")
    func classifierChunkedConservative() {
        // Transfer-Encoding: chunked has no Content-Length to compare; we
        // must NOT false-alarm .overflowed — conservative .captured.
        let buf = Self.headBuffer(
            headers: ["Host: api.example.com", "Transfer-Encoding: chunked"],
            bodyBytes: Array("5\r\nhello\r\n".utf8))
        #expect(MITMUpstreamVerify.innerBodyCaptureState(fromHeadBuffer: buf) == .captured)
    }

    @Test("declaredContentLength: malformed value → nil (don't guess)")
    func declaredContentLengthMalformed() {
        let buf = Self.headBuffer(
            headers: ["Host: api.example.com", "Content-Length: not-a-number"],
            bodyBytes: Array("x".utf8))
        #expect(MITMUpstreamVerify.declaredContentLength(fromHeadBuffer: buf) == nil)
        // Malformed CL → classifier falls through to .captured (body present,
        // no usable length → never false .overflowed).
        #expect(MITMUpstreamVerify.innerBodyCaptureState(fromHeadBuffer: buf) == .captured)
    }

    // MARK: - 2. Migration landed + anchor opened

    @Test("v47 ALTER lands body_excerpt_capture_state column + opens exactly one migration-v47 anchor")
    func migrationLandsColumnAndAnchor() {
        let path = Self.tempDBPath()
        defer { TempSessionDatabase.cleanup(path: path) }
        let db = SessionDatabase(path: path)
        defer { db.close() }

        let cols = Self.columnNames(path: path)
        #expect(cols.contains("body_excerpt_capture_state"),
                "v47 ALTER for body_excerpt_capture_state did not land")
        // v46 column must still be present (additive migration).
        #expect(cols.contains("body_excerpt"), "v46 body_excerpt column regressed")

        #expect(Self.anchorCount(path: path, reason: "migration-v47") == 1,
                "first open must open exactly one migration-v47 anchor")
    }

    // MARK: - 3. Round-trips byte-identical + chain verifies

    @Test("Capture-state persists and round-trips; chain verifies post-v47")
    func captureStateRoundTripsAndChainVerifies() {
        let path = Self.tempDBPath()
        defer { TempSessionDatabase.cleanup(path: path) }
        let db = SessionDatabase(path: path)
        defer { db.close() }

        // Write one row per known state.
        let cases: [(state: EgressBodyCaptureState, body: Data?)] = [
            (.captured, Data("{\"x\":1}".utf8)),
            (.empty, nil),
            (.overflowed, Data("prefix-only".utf8)),
            (.extractionFailed, nil),
        ]
        for (state, body) in cases {
            #expect(db.recordEgressDecision(
                host: "api.example.com", method: "POST",
                decision: .allow, ruleId: "test-rule",
                latencyUs: 100, paneMode: .general,
                judgeRationale: nil, bodyExcerpt: body,
                bodyExcerptCaptureState: state),
                "record failed for state \(state.rawValue)")
        }

        // Read back (descending id) and assert each state round-tripped.
        let rows = db.recentEgressDecisions(limit: 10)
        #expect(rows.count == 4)
        let readStates = Set(rows.compactMap { $0.bodyExcerptCaptureState })
        #expect(readStates == Set(EgressBodyCaptureState.allCases),
                "all four capture states must round-trip distinctly")

        // The load-bearing contract: the canonical-map insertion used the
        // SAME bytes (the rawValue text) we persisted, so the verifier
        // re-derives identically.
        switch ChainVerifier.verifyEgressDecisions(db) {
        case .ok:
            break  // expected
        case .brokenAt(let table, let rowid, let exp, let act):
            Issue.record("expected .ok, got brokenAt \(table):\(rowid) expected=\(exp) actual=\(act) — capture_state canonical bytes differ from persisted")
        case .noChain:
            Issue.record("expected .ok, got .noChain")
        }
    }

    @Test("A nil capture-state round-trips as NULL and chain still verifies (defaulted call site)")
    func nilCaptureStateRoundTrips() {
        let path = Self.tempDBPath()
        defer { TempSessionDatabase.cleanup(path: path) }
        let db = SessionDatabase(path: path)
        defer { db.close() }

        // No capture-state annotation (defaulted call site, e.g. a deny row).
        #expect(db.recordEgressDecision(
            host: "api.example.com", method: "GET",
            decision: .deny, ruleId: "default-deny",
            latencyUs: 100, paneMode: .general,
            judgeRationale: nil))

        let rows = db.recentEgressDecisions(limit: 1)
        #expect(rows.first?.bodyExcerptCaptureState == nil,
                "unannotated row must read back nil capture-state")

        switch ChainVerifier.verifyEgressDecisions(db) {
        case .ok: break
        default: Issue.record("nil capture-state row must still chain-verify")
        }
    }

    // MARK: - 4. Doctor surface helpers

    @Test("countByCaptureState returns all four states in canonical order + unannotated count")
    func countByCaptureStateShape() {
        func row(_ s: EgressBodyCaptureState?) -> EgressDecisionStore.Row {
            EgressDecisionStore.Row(
                id: 0, timestamp: Date(), host: "h", method: "POST",
                decision: .allow, ruleId: "r", latencyUs: 1,
                paneId: nil, projectRoot: nil, paneMode: nil,
                judgeRationale: nil, bodyExcerpt: nil,
                bodyExcerptCaptureState: s)
        }
        let rows = [
            row(.captured), row(.captured), row(.overflowed),
            row(.empty), row(nil), row(nil), row(nil),
        ]
        let result = MITMBodyInspectionCorpus.countByCaptureState(rows)
        // Fixed canonical order: empty, overflowed, extraction_failed, captured.
        #expect(result.states.map { $0.state } == EgressBodyCaptureState.allCases)
        let byState = Dictionary(uniqueKeysWithValues: result.states.map { ($0.state, $0.count) })
        #expect(byState[.captured] == 2)
        #expect(byState[.overflowed] == 1)
        #expect(byState[.empty] == 1)
        #expect(byState[.extractionFailed] == 0)
        #expect(result.unannotated == 3)
    }

    @Test("formatCheckEgressMITMStateLines: capture-state line present when counts supplied, caveat stays last")
    func formatterCaptureStateLine() {
        let counts = MITMBodyInspectionCorpus.countByCaptureState([
            EgressDecisionStore.Row(
                id: 0, timestamp: Date(), host: "h", method: "POST",
                decision: .allow, ruleId: "r", latencyUs: 1,
                paneId: nil, projectRoot: nil, paneMode: nil,
                judgeRationale: nil, bodyExcerpt: nil,
                bodyExcerptCaptureState: .overflowed),
        ])
        let lines = MITMBodyInspectionCorpus.formatCheckEgressMITMStateLines(
            flagOn: true, caOnDisk: true,
            bodyCorpusPassed: 8, bodyCorpusTotal: 8,
            recentDenialCounts: [],
            captureStateCounts: counts)
        let captureLine = lines.first { $0.hasPrefix("body capture states") }
        #expect(captureLine != nil, "capture-state line must be present when counts supplied")
        #expect(captureLine?.contains("overflowed=1") == true)
        // Caveat must remain the LAST line in all states.
        #expect(lines.last?.hasPrefix("note: body/header/path DENY rules") == true,
                "caveat footer must stay last")
    }

    @Test("formatCheckEgressMITMStateLines: capture-state line OMITTED when counts nil (back-compat)")
    func formatterBackCompatNoCaptureLine() {
        let lines = MITMBodyInspectionCorpus.formatCheckEgressMITMStateLines(
            flagOn: false, caOnDisk: false,
            bodyCorpusPassed: 8, bodyCorpusTotal: 8,
            recentDenialCounts: [])
        #expect(!lines.contains { $0.hasPrefix("body capture states") },
                "no capture-state line when counts not supplied (pre-r-followups callers)")
    }
}
