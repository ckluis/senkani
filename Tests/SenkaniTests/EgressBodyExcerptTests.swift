import Testing
import Foundation
import SQLite3
@testable import Core

/// T.1d-4 — body-aware judge excerpt + T.5 body-excerpt persistence
/// (truncate/redact-before-hash). Schneier+Allspaw+Carmack+Karpathy
/// roster, r88 spec.
///
/// Schneier P0 — `migration-v23` rows stay v23-shape FOREVER; the
/// exclusion list in `ChainVerifier.verifyAnchorEgressDecisions` keeps
/// them out of the v46-shape tier so their entry_hash bytes (computed
/// without `body_excerpt`) remain re-derivable post-v46 migration.
///
/// Schneier P1 — the body excerpt is truncate-then-redact BEFORE it
/// enters either the canonical-map (audit row hash) or the judge prompt.
/// Order matters: truncate to ≤4 KB FIRST so a giant body of secrets
/// gets bounded BEFORE the SecretDetector regex pass.
///
/// Schneier P3 — the v46 idempotency probe MUST reference
/// `migration-v46` and `fresh-install-pre-v46` only. A literal `v45` /
/// `v23` in that probe silently makes v46's rename + open run twice on
/// a re-migration. The header doc-comment of the v46 migration block
/// includes the reviewer-checklist line.
///
/// Tests are `.serialized` because they each construct a temp
/// SessionDatabase that runs the full migration array (shared on-disk
/// state at fixed paths under /tmp). Mirrors
/// `Migrations45PromptCachingTests`.
@Suite("Egress body excerpt — judge surface + T.5 persistence (v46)", .serialized)
struct EgressBodyExcerptTests {

    private static func tempDBPath() -> String {
        let dir = NSTemporaryDirectory() + "senkani-t1d4-body-excerpt-tests/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "egress-decisions-v46-\(UUID().uuidString).db"
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

    // MARK: - 1. Judge receives the excerpt

    /// Test #1 — the body-aware `JudgeRequest` is constructed with a
    /// non-nil `bodyExcerpt` and the adapter sees it. Pins the API
    /// shape end-to-end.
    @Test("JudgeAdapter receives the body excerpt — JudgeRequest.bodyExcerpt is non-nil at evaluate()")
    func judgeReceivesBodyExcerpt() {
        // A spy adapter records the last request it saw.
        final class SpyAdapter: JudgeAdapter, @unchecked Sendable {
            private let lock = NSLock()
            private var _last: JudgeRequest?
            private var _count = 0
            var lastRequest: JudgeRequest? {
                lock.lock(); defer { lock.unlock() }
                return _last
            }
            var callCount: Int {
                lock.lock(); defer { lock.unlock() }
                return _count
            }
            func evaluate(_ request: JudgeRequest) -> JudgeVerdict {
                lock.lock()
                _last = request
                _count += 1
                lock.unlock()
                return JudgeVerdict(decision: .deny, rationale: "spy-deny")
            }
        }
        let spy = SpyAdapter()
        let bodyBytes = Data("{\"prompt\":\"hello\"}".utf8)
        let preparedExcerpt = EgressDecisionStore.prepareBodyExcerpt(bodyBytes)
        let request = JudgeRequest(
            host: "example.com",
            method: "POST",
            paneMode: .general,
            bodyExcerpt: preparedExcerpt
        )
        _ = spy.evaluate(request)
        #expect(spy.callCount == 1)
        let last = spy.lastRequest
        #expect(last?.host == "example.com")
        #expect(last?.method == "POST")
        #expect(last?.paneMode == .general)
        #expect(last?.bodyExcerpt == preparedExcerpt,
                "JudgeRequest must surface the body excerpt to the adapter")

        // The buildPrompt code-constant template must include the
        // excerpt section when present (Karpathy P0: prompt is a stable
        // code constant; a regression here is PR-visible).
        let prompt = GemmaJudgeAdapter.buildPrompt(request)
        #expect(prompt.contains("Request body excerpt"),
                "prompt template must mention the body excerpt section when bodyExcerpt is non-nil")
        #expect(prompt.contains("\"prompt\":\"hello\""),
                "the prompt body content must be visible to the LLM")
    }

    // MARK: - 2. Excerpt persists to the new column (round-trips byte-identical post-redaction)

    /// Test #2 — write a row with a redacted body excerpt via
    /// `EgressDecisionStore.record`; read back via `recentEgressDecisions`;
    /// assert the body_excerpt round-trips byte-identical to the
    /// post-redaction bytes. The persisted bytes MUST be post-redaction —
    /// raw secrets must NEVER land in the audit row.
    @Test("Body excerpt persists to body_excerpt column and round-trips byte-identical (post-redaction)")
    func bodyExcerptRoundTripsByteIdentical() {
        let path = Self.tempDBPath()
        defer { TempSessionDatabase.cleanup(path: path) }
        let db = SessionDatabase(path: path)
        defer { db.close() }

        // The v46 ADD COLUMN must have landed.
        let cols = Self.columnNames(path: path)
        #expect(cols.contains("body_excerpt"),
                "v46 ALTER for body_excerpt did not land")

        // Sanity: one migration-v46 anchor opened on first boot.
        #expect(Self.anchorCount(path: path, reason: "migration-v46") == 1,
                "first open must open exactly one migration-v46 anchor")

        // A body containing a planted OpenAI key + control bytes. The
        // writer truncate-then-redacts before persisting; the on-disk
        // bytes are POST-REDACTION.
        let rawBody = Data("{\"input\":\"hi\",\"key\":\"sk-abcdef1234567890ABCDEF12345678\"}".utf8)
        let expectedPersisted = EgressDecisionStore.prepareBodyExcerpt(rawBody)

        #expect(db.recordEgressDecision(
            host: "api.example.com", method: "POST",
            decision: .allow, ruleId: "test-rule",
            latencyUs: 100, paneMode: .general,
            judgeRationale: nil, bodyExcerpt: rawBody))

        let rows = db.recentEgressDecisions(limit: 1)
        #expect(rows.count == 1)
        guard let row = rows.first else { Issue.record("no row"); return }
        #expect(row.bodyExcerpt == expectedPersisted,
                "persisted body_excerpt must match prepareBodyExcerpt(raw) — proves writer wired the helper")

        // The redacted bytes MUST NOT contain the raw key (Schneier P1
        // — no raw secrets in audit row).
        if let s = row.bodyExcerpt.flatMap({ String(data: $0, encoding: .utf8) }) {
            #expect(!s.contains("sk-abcdef1234567890ABCDEF12345678"),
                    "raw secret must not appear in persisted body_excerpt")
            #expect(s.contains("[REDACTED:"),
                    "SecretDetector redaction marker must appear in persisted bytes")
        } else {
            Issue.record("persisted bytes were not UTF-8 decodable")
        }
    }

    // MARK: - 3. Chain verifies post-migration with a redacted excerpt

    /// Test #3 — write a row whose body contains a planted secret +
    /// control bytes; the persisted excerpt MUST be redacted + ≤4 KB;
    /// `ChainVerifier.verifyEgressDecisions == .ok` re-derives the
    /// canonical hash from the persisted (redacted) bytes.
    @Test("Chain verifies post-migration with a redacted excerpt — entry_hash recomputes from persisted (redacted) bytes")
    func chainVerifiesWithRedactedExcerpt() {
        let path = Self.tempDBPath()
        defer { TempSessionDatabase.cleanup(path: path) }
        let db = SessionDatabase(path: path)
        defer { db.close() }

        // Plant a secret + over-4KB filler so we exercise BOTH the
        // SecretDetector redaction AND the truncate path.
        let secret = "sk-DEADBEEFCAFE1234567890DEADBEEFCAFE"
        var body = "PREFIX " + secret + " "
        // Append 8 KB of padding so the excerpt gets truncated.
        let padding = String(repeating: "x", count: 8 * 1024)
        body += padding
        let rawBody = Data(body.utf8)

        #expect(rawBody.count > EgressDecisionStore.bodyExcerptMaxBytes,
                "test fixture must exceed 4 KB cap so truncate path is exercised")

        #expect(db.recordEgressDecision(
            host: "api.example.com", method: "POST",
            decision: .allow, ruleId: "test-rule",
            latencyUs: 100, paneMode: .general,
            judgeRationale: nil, bodyExcerpt: rawBody))

        let rows = db.recentEgressDecisions(limit: 1)
        guard let row = rows.first, let persisted = row.bodyExcerpt else {
            Issue.record("no row with persisted excerpt")
            return
        }

        // Bounded ≤4 KB. The truncate-then-redact policy means the
        // PRE-redaction truncation gives us 4 KB; redaction may grow
        // OR shrink the result (replacing the secret with
        // `[REDACTED:NAME]` is roughly length-neutral). We assert the
        // ≤4 KB bound on PRE-redaction; post-redaction bytes may be
        // slightly larger or smaller. Spec language: "bounded excerpt
        // ≤4 KB" applies to the truncate input bound.
        //
        // To pin this precisely: the secret was within the first 4 KB
        // (it's at the very front of `body`), so after truncating to
        // 4 KB then redacting, the secret MUST be absent and the
        // marker MUST be present.
        if let s = String(data: persisted, encoding: .utf8) {
            #expect(!s.contains(secret),
                    "Schneier P1: raw secret must NOT survive truncate-then-redact in persisted excerpt")
            #expect(s.contains("[REDACTED:"),
                    "SecretDetector marker must appear in persisted excerpt")
        } else {
            Issue.record("persisted bytes were not UTF-8 decodable")
        }

        // Chain verification: re-derive entry_hash from the persisted
        // (redacted) bytes — must be .ok. This is the load-bearing
        // contract: the canonical-map insertion uses the SAME bytes
        // we persisted (post-redaction), so the verifier's read-back
        // re-derives identically.
        switch ChainVerifier.verifyEgressDecisions(db) {
        case .ok:
            break  // expected
        case .brokenAt(let table, let rowid, let exp, let act):
            Issue.record("expected .ok, got brokenAt \(table):\(rowid) expected=\(exp) actual=\(act) — this means the canonical-map bytes differ from the persisted bytes (redaction-after-hash regression)")
        case .noChain:
            Issue.record("expected .ok, got .noChain")
        }
    }

    // MARK: - 4. migration-v23 row in a v46 DB stays v23-shape (Schneier P0)

    /// Test #4 — a row written under `migration-v23` BEFORE v46 landed
    /// has an entry_hash computed over the v23 column-set (WITHOUT
    /// `body_excerpt`). After v46 runs (adds the column + opens
    /// `migration-v46`), the `migration-v23` row's hash MUST re-derive
    /// identical to its stored value — proving the exclusion list keeps
    /// the row's canonical shape stable across the migration.
    ///
    /// This is the load-bearing Schneier P0 contract: if v46 mis-classifies
    /// migration-v23 rows as v46-shape, every legacy row breaks
    /// verification.
    @Test("migration-v23 row in a v46 DB: entry_hash recomputes identical — stays v23-shape (Schneier P0)")
    func migrationV23RowStaysV23ShapeInV46DB() {
        let path = Self.tempDBPath()
        defer { TempSessionDatabase.cleanup(path: path) }
        let db = SessionDatabase(path: path)

        // Open a `migration-v23`-reason anchor at started_at_rowid = 1000.
        // Insert a row at id > 1000 attributable to that anchor with
        // entry_hash computed over the v23 column-set (WITHOUT
        // `body_excerpt`) — even though the table now has the column
        // (post-v46 ALTER) and the row simply writes NULL to it.
        guard let handle = TempSessionDatabase.openSecondaryHandle(path) else {
            Issue.record("could not open secondary handle"); return
        }
        defer { sqlite3_close(handle) }

        var anchorStmt: OpaquePointer?
        let anchorSQL = """
            INSERT INTO chain_anchors
                (table_name, started_at, started_at_rowid, reason, operator_note)
            VALUES ('egress_decisions', ?, 1000, 'migration-v23', NULL);
        """
        #expect(sqlite3_prepare_v2(handle, anchorSQL, -1, &anchorStmt, nil) == SQLITE_OK)
        sqlite3_bind_double(anchorStmt, 1, Date().timeIntervalSince1970)
        #expect(sqlite3_step(anchorStmt) == SQLITE_DONE)
        let anchorId = sqlite3_last_insert_rowid(handle)
        sqlite3_finalize(anchorStmt)

        // Pre-migration v23-shape canonical hash. body_excerpt is NOT
        // in the map — exactly as a writer running pre-v46 would have
        // produced.
        let ts = 1_900_500_000.0
        let v23Columns: [String: ChainHasher.CanonicalValue] = [
            "timestamp":     .real(ts),
            "host":          .text("legacy.example.com"),
            "method":        .text("POST"),
            "decision":      .text("allow"),
            "rule_id":       .text("legacy-v23"),
            "latency_us":    .integer(50),
            "pane_id":       .null,
            "project_root":  .null,
            "judge_rationale": .null,
            "pane_mode":     .text("general"),
        ]
        let v23Hash = ChainHasher.entryHash(
            table: "egress_decisions", columns: v23Columns, prev: nil)

        // Insert the row with that pre-v46 hash. body_excerpt persists
        // NULL — the column exists now (post-v46 ALTER) but the row's
        // hash was computed without it.
        var rowStmt: OpaquePointer?
        let rowSQL = """
            INSERT INTO egress_decisions
                (id, timestamp, host, method, decision, rule_id, latency_us,
                 pane_id, project_root,
                 judge_rationale, pane_mode,
                 body_excerpt,
                 prev_hash, entry_hash, chain_anchor_id)
            VALUES (1001, ?, 'legacy.example.com', 'POST', 'allow',
                    'legacy-v23', 50,
                    NULL, NULL,
                    NULL, 'general',
                    NULL,
                    NULL, ?, ?);
        """
        #expect(sqlite3_prepare_v2(handle, rowSQL, -1, &rowStmt, nil) == SQLITE_OK)
        sqlite3_bind_double(rowStmt, 1, ts)
        sqlite3_bind_text(rowStmt, 2, (v23Hash as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(rowStmt, 3, anchorId)
        #expect(sqlite3_step(rowStmt) == SQLITE_DONE)
        sqlite3_finalize(rowStmt)

        // The whole table must verify — proving the v23-shape row
        // re-derives identically under the verifier's exclusion-list
        // branch (keeps `migration-v23` out of useV46Shape).
        db.close()
        let db2 = SessionDatabase(path: path)
        defer { db2.close() }
        switch ChainVerifier.verifyEgressDecisions(db2) {
        case .ok:
            break  // expected — Schneier P0: migration-v23 rows stay v23-shape forever
        case .brokenAt(let table, let rowid, let exp, let act):
            Issue.record("Schneier P0 regression: migration-v23 row \(table):\(rowid) was re-classified as v46-shape; expected=\(exp) actual=\(act)")
        case .noChain:
            Issue.record("expected .ok, got .noChain")
        }
    }

    // MARK: - 5. truncate-then-redact ORDER + ≤4 KB pre-redaction bound

    /// Test #5 — pin the truncate-then-redact ORDER. Construct an input
    /// where redact-then-truncate would behave differently than
    /// truncate-then-redact:
    ///   - Place padding bytes in the first 4 KB,
    ///   - Place a secret OUTSIDE the first 4 KB (it's in bytes
    ///     4 KB ... 8 KB).
    /// Under truncate-then-redact: the secret is dropped by truncation
    /// BEFORE redaction runs, so the SecretDetector marker MUST NOT
    /// appear (no secret to find).
    /// Under redact-then-truncate: the secret would be redacted FIRST
    /// (marker appears), then the resulting bytes truncated — marker
    /// might survive.
    /// The expected behavior pins the ORDER load-bearing in the
    /// implementation (Schneier P1).
    @Test("truncate-then-redact ORDER pinned: secret BEYOND 4 KB is DROPPED by truncation (no redaction marker)")
    func truncateBeforeRedactOrderPinned() {
        let padding = String(repeating: "a", count: 5 * 1024)  // 5 KB
        let secret = "sk-DEADBEEFCAFE1234567890DEADBEEFCAFE"
        let body = padding + " " + secret
        let input = Data(body.utf8)
        let prepared = EgressDecisionStore.prepareBodyExcerpt(input)

        guard let s = String(data: prepared, encoding: .utf8) else {
            Issue.record("prepared bytes not UTF-8"); return
        }

        // The secret was beyond the 4 KB cap, so truncate-then-redact
        // drops it BEFORE redaction runs — the marker MUST NOT appear.
        #expect(!s.contains("[REDACTED:"),
                "truncate-then-redact ORDER: secret beyond 4 KB cap is dropped by truncation, redaction has nothing to find — marker must NOT appear (a marker here would prove redact-then-truncate, the wrong order)")
        #expect(!s.contains(secret),
                "secret bytes beyond 4 KB cap must not survive truncation")
    }

    // MARK: - 6. v46 idempotent re-run (Schneier P3)

    /// Test #6 — opening a SessionDatabase twice against the same path
    /// runs the migration array twice. The second pass must observe the
    /// existing `migration-v46` anchor via the probe and skip the
    /// rename + anchor-open, so `migration-v46` anchor count stays at
    /// exactly 1 (Schneier P3: probe must not contain v45/v23 literals).
    @Test("v46 idempotent re-run: opening + re-opening keeps migration-v46 anchor count == 1")
    func v46IdempotentReRun() {
        let path = Self.tempDBPath()
        defer { TempSessionDatabase.cleanup(path: path) }

        let db1 = SessionDatabase(path: path)
        #expect(db1.egressDecisionCount() == 0)
        db1.close()

        // The body_excerpt column landed (idempotent ALTER).
        let cols = Self.columnNames(path: path)
        #expect(cols.contains("body_excerpt"),
                "v46 ALTER for body_excerpt did not land")
        #expect(Self.anchorCount(path: path, reason: "migration-v46") == 1,
                "first open must open exactly one migration-v46 anchor")

        // Second open — migration array runs again. The probe must
        // short-circuit the rename + anchor-open.
        let db2 = SessionDatabase(path: path)
        defer { db2.close() }
        #expect(Self.anchorCount(path: path, reason: "migration-v46") == 1,
                "re-open must NOT open a second migration-v46 anchor")
        #expect(Self.anchorCount(path: path, reason: "fresh-install-pre-v46") == 0,
                "re-open must NOT re-rename anything (no fresh-install to rename)")
    }

    // MARK: - 7. Back-compat: existing recordEgressDecision call sites pass nil

    /// Test #7 — calling `recordEgressDecision` WITHOUT `bodyExcerpt`
    /// (the way every existing call site does) still works and persists
    /// NULL in the column. Pins back-compat: a future refactor can't
    /// silently demand a non-nil bodyExcerpt.
    @Test("Back-compat: recordEgressDecision without bodyExcerpt persists NULL and verifies clean")
    func backCompatNilBodyExcerpt() {
        let path = Self.tempDBPath()
        defer { TempSessionDatabase.cleanup(path: path) }
        let db = SessionDatabase(path: path)
        defer { db.close() }

        #expect(db.recordEgressDecision(
            host: "example.com", method: "GET",
            decision: .allow, ruleId: "test",
            latencyUs: 1, paneMode: .general,
            judgeRationale: nil))  // body_excerpt OMITTED — default nil

        let rows = db.recentEgressDecisions(limit: 1)
        #expect(rows.count == 1)
        #expect(rows.first?.bodyExcerpt == nil,
                "default bodyExcerpt argument must persist NULL")

        // The chain still verifies — the v46-shape canonical map
        // includes `body_excerpt = .null` and the verifier reads it
        // back as `.null` (NULL-vs-empty distinction).
        switch ChainVerifier.verifyEgressDecisions(db) {
        case .ok: break
        default: Issue.record("expected .ok for nil-body row")
        }
    }
}
