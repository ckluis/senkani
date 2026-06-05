import Foundation
import SQLite3

/// Why an audit row's `body_excerpt` came out the way it did.
///
/// T.1d-5 r52 Allspaw P2 (v47): before this column, an audit row with
/// `body_excerpt: nil` was AMBIGUOUS — it could mean any of:
///   - `.empty`            — no body was sent (GET/HEAD, or an explicit
///                           Content-Length:0 POST). The request HEAD
///                           terminated with `\r\n\r\n` and nothing
///                           followed.
///   - `.overflowed`       — a body WAS sent but its declared length
///                           exceeded what fit in the ≤16 KB rebind-peek
///                           head buffer, so the captured excerpt is a
///                           PREFIX (or, if the body started past the
///                           buffer boundary, nothing was captured). An
///                           operator seeing a spike here knows the
///                           16 KB peek window is undersized for their
///                           traffic.
///   - `.extractionFailed` — the head buffer was malformed (no
///                           `\r\n\r\n` terminator, or fewer than 4
///                           bytes). Defensively (near-)unreachable from
///                           the live `.allow` arm — the rebind peek
///                           guarantees a terminator before it returns
///                           `.allow(headBytes:)` — but the classifier
///                           pins the contract so a future caller that
///                           feeds an unvalidated buffer gets an honest
///                           state instead of a false `.empty`.
///   - `.captured`         — a body was present and its excerpt bytes
///                           were captured (possibly truncate-then-
///                           redacted by `prepareBodyExcerpt`, but the
///                           full declared body fit the head buffer).
///
/// Persisted as the `rawValue` TEXT in the `body_excerpt_capture_state`
/// column. The rawValues are a STABLE on-disk vocabulary — never rename
/// a case's rawValue (it would break audit-chain re-derivation for rows
/// already written under that string). Pre-v47 rows carry NULL (the
/// column did not exist); the verifier omits the column for pre-v47
/// anchors so those rows re-derive byte-identically.
public enum EgressBodyCaptureState: String, Sendable, Equatable, CaseIterable {
    case empty
    case overflowed
    case extractionFailed = "extraction_failed"
    case captured
}

/// Owns `egress_decisions` end-to-end: schema (migration v19), chained
/// writes, recent-row reads. Mirrors `TokenEventStore`'s shape so the
/// chain mechanics are uniform across participants.
///
/// Concurrency: every `sqlite3_*` call against `parent.db` runs on
/// `parent.queue` (the SessionDatabase queue-affinity invariant from
/// the 2026-05-04 audit). The chain state cache lives inside
/// `ChainState` which is shared with the other chain participants.
public final class EgressDecisionStore: @unchecked Sendable {
    private unowned let parent: SessionDatabase
    private let chain = ChainState(table: "egress_decisions")

    init(parent: SessionDatabase) {
        self.parent = parent
    }

    /// Drop the chain cache after a `--repair-chain` motion. Caller
    /// must already be on `parent.queue`.
    func invalidateChainCache() { chain.invalidate() }

    /// Record a decision. Synchronous-on-queue so unit tests can read
    /// the row back immediately after writing — the live listener
    /// (T.1a.2) calls this through the same dispatch path and gets the
    /// same guarantee. Returns true on success, false on any SQLite
    /// failure (logged, not thrown — egress decisions are best-effort
    /// from the daemon's point of view: a write failure must NOT
    /// crash the listener).
    @discardableResult
    public func record(
        host: String,
        method: String,
        decision: EgressRule.Decision,
        ruleId: String,
        latencyUs: Int64,
        paneId: String? = nil,
        projectRoot: String? = nil,
        paneMode: PaneMode? = nil,
        judgeRationale: String? = nil,
        bodyExcerpt: Data? = nil,
        bodyExcerptCaptureState: EgressBodyCaptureState? = nil
    ) -> Bool {
        let normalizedRoot = SessionDatabase.normalizePath(projectRoot)
        // T.1d-4 Schneier P1: truncate-then-redact the body excerpt BEFORE
        // it enters the canonical-map / SQLite bind. Truncate first to
        // ≤4 KB so a giant body of secrets gets bounded BEFORE the
        // SecretDetector regex pass (saves cycles on bytes that'd be
        // dropped). The on-disk bytes are post-redaction — the audit row
        // NEVER contains raw secrets.
        //
        // Callers that pass nil get nil on-disk: existing pre-T.1d-4
        // recordEgressDecision sites stay byte-identical to their v23
        // shape output (only the .null body_excerpt slot is added to the
        // canonical map, distinct from "no body_excerpt slot at all"
        // under pre-v46 anchors).
        let preparedExcerpt: Data? = bodyExcerpt.map { Self.prepareBodyExcerpt($0) }
        let now = Date().timeIntervalSince1970
        return parent.queue.sync { [parent, chain] in
            guard let db = parent.db else { return false }
            let anchorId = chain.resolveAnchorId(db: db)
            let prevHash = chain.latestEntryHash(db: db, anchorId: anchorId)
            // T.1b: include `judge_rationale` + `pane_mode` in the
            // canonical column map for all anchors EXCEPT the legacy
            // pre-v23 `fresh-install-pre-v23` whose existing rows were
            // hashed without them. Post-v23 anchors (migration-v23,
            // post-v23 fresh-install, future repair-* rebinds) use
            // the new shape. Mirrored in
            // `ChainVerifier.verifyAnchorEgressDecisions`.
            //
            // T.1d-4: include `body_excerpt` in the canonical column map
            // for v46+ anchors (`migration-v46`, post-v46 `fresh-install`,
            // future `repair-*`). The three pre-v46 anchor reasons —
            // `fresh-install-pre-v23`, `migration-v23`,
            // `fresh-install-pre-v46` — OMIT the column (Schneier P0:
            // those rows were hashed under their respective shapes and
            // stay there forever). Mirrors the verifier's exclusion-list
            // branch in `ChainVerifier.verifyAnchorEgressDecisions`.
            let reason = chain.anchorReason(db: db, anchorId: anchorId) ?? ""
            let useLegacyShape = (reason == "fresh-install-pre-v23")
            let useV46Shape = ![
                "fresh-install-pre-v23", "migration-v23", "fresh-install-pre-v46",
            ].contains(reason)
            // T.1d-5 r52 Allspaw P2 (v47): include `body_excerpt_capture_state`
            // in the canonical column map for v47+ anchors (`migration-v47`,
            // post-v47 `fresh-install`, future `repair-*`). The FOUR pre-v47
            // anchor reasons — the three pre-v46 reasons PLUS `migration-v46`
            // — OMIT the column (Schneier P0: `migration-v46` rows were hashed
            // under the v46 shape that had NO capture_state column and stay
            // there forever). Mirrors the verifier's exclusion-list branch in
            // `ChainVerifier.verifyAnchorEgressDecisions`. EXCLUSION-form (not
            // an allowlist) so a future `repair-*` rebind inherits the v47
            // shape automatically.
            let useV47Shape = ![
                "fresh-install-pre-v23", "migration-v23", "fresh-install-pre-v46",
                "migration-v46", "fresh-install-pre-v47",
            ].contains(reason)

            var columns: [String: ChainHasher.CanonicalValue] = [
                "timestamp":     .real(now),
                "host":          .text(host),
                "method":        .text(method),
                "decision":      .text(decision.rawValue),
                "rule_id":       .text(ruleId),
                "latency_us":    .integer(latencyUs),
                "pane_id":       paneId.map { .text($0) } ?? .null,
                "project_root":  normalizedRoot.map { .text($0) } ?? .null,
            ]
            if !useLegacyShape {
                columns["judge_rationale"] = judgeRationale.map { .text($0) } ?? .null
                columns["pane_mode"] = paneMode.map { .text($0.rawValue) } ?? .null
            }
            if useV46Shape {
                // r89 P3 (Karpathy): NULL-vs-EMPTY body policy pin —
                // `.some(Data())` (empty body excerpt) flows through
                // `prepareBodyExcerpt(Data()) -> Data()` and then
                // `.blob(Data())` on the canonical map, which hashes
                // DISTINCTLY from `.null` (the `.none` case). The
                // distinction is by-design: an explicit empty-body
                // request is a different event than a no-body-captured
                // request (e.g. a GET with no body vs a POST whose body
                // bytes weren't extracted). The canonical-map hash
                // therefore distinguishes them on disk. See the
                // `AdversarialBodyCorpus.scenarios()` corpus for the
                // pin test ("inner-host-mismatch" carries an EMPTY
                // representativeBodyExcerpt and rounds-trips as a
                // distinct row from a nil-body row of the same shape).
                columns["body_excerpt"] = preparedExcerpt.map { .blob($0) } ?? .null
            }
            if useV47Shape {
                // v47 Allspaw P2: capture-state annotation. nil → .null in
                // the canonical map (distinct from any non-null state's
                // rawValue text), matching the NULL-vs-present policy the
                // body_excerpt slot uses. A nil capture-state means "the
                // caller did not annotate" — which a v47-aware writer never
                // does for a real CONNECT-path body, but defaulted call
                // sites (plain-HTTP, synthetic test rows) legitimately pass
                // nil and round-trip as NULL.
                columns["body_excerpt_capture_state"] =
                    bodyExcerptCaptureState.map { .text($0.rawValue) } ?? .null
            }
            let entryHash = ChainHasher.entryHash(
                table: "egress_decisions", columns: columns, prev: prevHash
            )

            let sql = """
                INSERT INTO egress_decisions
                    (timestamp, host, method, decision, rule_id, latency_us,
                     pane_id, project_root,
                     judge_rationale, pane_mode,
                     body_excerpt,
                     body_excerpt_capture_state,
                     prev_hash, entry_hash, chain_anchor_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, now)
            sqlite3_bind_text(stmt, 2, (host as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 3, (method as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 4, (decision.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 5, (ruleId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 6, latencyUs)
            if let paneId {
                sqlite3_bind_text(stmt, 7, (paneId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            if let normalizedRoot {
                sqlite3_bind_text(stmt, 8, (normalizedRoot as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            if let judgeRationale {
                sqlite3_bind_text(stmt, 9, (judgeRationale as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            if let paneMode {
                sqlite3_bind_text(stmt, 10, (paneMode.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            if let preparedExcerpt {
                _ = preparedExcerpt.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
                    sqlite3_bind_blob(stmt, 11, raw.baseAddress, Int32(preparedExcerpt.count), SQLITE_TRANSIENT_DESTRUCTOR)
                }
            } else {
                sqlite3_bind_null(stmt, 11)
            }
            // v47 capture-state. Bind the rawValue text (or NULL when the
            // caller didn't annotate). On-disk value is always the canonical
            // rawValue string so the read-back + verifier re-derive
            // identically.
            if let bodyExcerptCaptureState {
                sqlite3_bind_text(stmt, 12, (bodyExcerptCaptureState.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            } else {
                sqlite3_bind_null(stmt, 12)
            }
            if let prevHash {
                sqlite3_bind_text(stmt, 13, (prevHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            } else {
                sqlite3_bind_null(stmt, 13)
            }
            sqlite3_bind_text(stmt, 14, (entryHash as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(stmt, 15, anchorId)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            chain.recordWrite(anchorId: anchorId, entryHash: entryHash)
            return true
        }
    }

    /// Truncate-then-redact the request-body excerpt that will land in
    /// the audit row + judge prompt.
    ///
    /// Schneier P1 (T.1d-4): order matters. Truncate to ≤4 KB FIRST so a
    /// giant body of secrets gets bounded BEFORE the SecretDetector
    /// regex pass (vs redact-then-truncate which would waste cycles
    /// redacting bytes that get dropped). The output is what's persisted
    /// AND what's handed to the judge — so the LLM never sees raw
    /// secrets either.
    ///
    /// Non-UTF8 bytes: SecretDetector is text-based, so bytes that don't
    /// decode as UTF-8 pass through unchanged (the regex pass can't
    /// process them and they're not text-shaped secrets). The audit row
    /// still records the truncated bytes — the integrity contract is
    /// "no raw text-format secrets land on disk", not "all bytes get
    /// canonicalized to ASCII".
    public static let bodyExcerptMaxBytes: Int = 4 * 1024

    public static func prepareBodyExcerpt(_ input: Data) -> Data {
        let truncated: Data = input.count > bodyExcerptMaxBytes
            ? input.prefix(bodyExcerptMaxBytes)
            : input
        guard let s = String(data: truncated, encoding: .utf8) else {
            // Non-UTF8 body — pass truncated bytes through. No raw
            // text-shaped secrets to scrub.
            return truncated
        }
        let scan = SecretDetector.scan(s)
        return Data(scan.redacted.utf8)
    }

    /// Decision row as read back from the table.
    public struct Row: Sendable, Equatable {
        public let id: Int64
        public let timestamp: Date
        public let host: String
        public let method: String
        public let decision: EgressRule.Decision
        public let ruleId: String
        public let latencyUs: Int64
        public let paneId: String?
        public let projectRoot: String?
        public let paneMode: PaneMode?
        public let judgeRationale: String?
        /// T.1d-4 — truncate-then-redact request-body excerpt
        /// (post-SecretDetector, ≤4 KB). nil for pre-v46 rows and for
        /// post-v46 rows where the connection handler did not capture a
        /// body (e.g. opaque-tunnel path, deny-before-MITM, GET with no
        /// body).
        public let bodyExcerpt: Data?
        /// T.1d-5 r52 Allspaw P2 (v47) — why `bodyExcerpt` came out the
        /// way it did. nil for pre-v47 rows and for post-v47 rows whose
        /// writer did not annotate (defaulted call sites). Lets the
        /// operator (via doctor `--check-egress`) distinguish a benign
        /// no-body GET from a body that overflowed the 16 KB peek window.
        public let bodyExcerptCaptureState: EgressBodyCaptureState?
    }

    /// Return the N most recent rows in descending id order. Used by
    /// `senkani egress status --decisions` (T.1a.2 follow-up CLI work
    /// hangs off this) and by the doctor check that reports decision
    /// count.
    public func recent(limit: Int = 100) -> [Row] {
        return parent.queue.sync {
            guard let db = parent.db else { return [] }
            let sql = """
                SELECT id, timestamp, host, method, decision, rule_id,
                       latency_us, pane_id, project_root,
                       pane_mode, judge_rationale, body_excerpt,
                       body_excerpt_capture_state
                  FROM egress_decisions
                 ORDER BY id DESC
                 LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var out: [Row] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let ts = sqlite3_column_double(stmt, 1)
                let host = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let method = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let decisionStr = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "deny"
                let ruleId = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                let latency = sqlite3_column_int64(stmt, 6)
                let paneId: String? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_text(stmt, 7).map { String(cString: $0) }
                let projectRoot: String? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_text(stmt, 8).map { String(cString: $0) }
                let paneModeStr: String? = sqlite3_column_type(stmt, 9) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_text(stmt, 9).map { String(cString: $0) }
                let judgeRationale: String? = sqlite3_column_type(stmt, 10) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_text(stmt, 10).map { String(cString: $0) }
                let bodyExcerpt: Data?
                if sqlite3_column_type(stmt, 11) == SQLITE_NULL {
                    bodyExcerpt = nil
                } else if let raw = sqlite3_column_blob(stmt, 11) {
                    let len = Int(sqlite3_column_bytes(stmt, 11))
                    bodyExcerpt = Data(bytes: raw, count: len)
                } else {
                    bodyExcerpt = Data()
                }
                let captureStateStr: String? = sqlite3_column_type(stmt, 12) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_text(stmt, 12).map { String(cString: $0) }
                let decision = EgressRule.Decision(rawValue: decisionStr) ?? .deny
                let paneMode = paneModeStr.flatMap { PaneMode(rawValue: $0) }
                let captureState = captureStateStr.flatMap { EgressBodyCaptureState(rawValue: $0) }
                out.append(Row(
                    id: id, timestamp: Date(timeIntervalSince1970: ts),
                    host: host, method: method, decision: decision, ruleId: ruleId,
                    latencyUs: latency, paneId: paneId, projectRoot: projectRoot,
                    paneMode: paneMode, judgeRationale: judgeRationale,
                    bodyExcerpt: bodyExcerpt,
                    bodyExcerptCaptureState: captureState
                ))
            }
            return out
        }
    }

    /// Total decision count. Cheap — uses COUNT(*) on the table. Doctor
    /// check surfaces this in the status line.
    public func count() -> Int64 {
        return parent.queue.sync {
            guard let db = parent.db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM egress_decisions;", -1, &stmt, nil) == SQLITE_OK else {
                return 0
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(stmt, 0)
        }
    }
}
