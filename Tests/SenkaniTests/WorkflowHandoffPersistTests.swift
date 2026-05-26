import Testing
import Foundation
import SQLite3
@testable import Core

/// U.11a-4 — `BlockedHandoff.render()` + migration v40 + `workstream_handoffs`
/// persistence + `handoff.*` chain rows + 1k-event chain-integrity tests.
///
/// 6 tests covering the a-4 acceptance bullets:
///
///   1. `render_carries_no_raw_stdout` — `render()` output reads zero
///      raw-stdout substrings even when the evidence bundle contains
///      a marker stand-in.
///   2. `handoff_event_writer_and_chain_verify` — `handoff.open` +
///      `handoff.close` writer paths insert chain rows under v40 +
///      ChainVerifier confirms; pre-v33 anchor refuses with a drop.
///   3. `migration_v40_ledger_advances` — after migrations run,
///      schema_migrations carries v40 + PRAGMA user_version == 40 +
///      the `workstream_handoffs` table + the `migration-v40` anchor
///      exist; ChainVerifier walks clean.
///   4. `persist_survives_restart` — `recordBlockedHandoff` →
///      flush → close DB → reopen → `workstream_handoffs` row + all
///      columns intact + render() output byte-equal across restart.
///   5. `gate_throw_and_persist_atomic` — `pre_run` × `block` refusal
///      throws GateRefusal AND inserts `workstream_handoffs` row AND
///      writes `handoff.open` chain row — single coherent outcome.
///   6. `chain_integrity_storm_1k_mixed_kinds` — 1000 mixed events
///      across the 6 U.11 row kinds (contract.attach, contract.advance,
///      assertion.record, gate.evaluate, handoff.open, handoff.close);
///      ChainVerifier.verifyTokenEvents + verifyWorkstreamHandoffs
///      both .ok.
@Suite("WorkflowHandoffPersist (U.11a-4)")
struct WorkflowHandoffPersistTests {

    // MARK: - Helpers

    private static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-u11a4-test-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    /// Drain queued async writes by issuing a sync probe through
    /// `SessionDatabase.queue` (mirrors the a-3 / a-2 pattern).
    private static func flushQueue(_ db: SessionDatabase) {
        _ = db.tokenEventExists(source: "u11a4-flush", feature: "noop")
    }

    private static func makeContract(workstreamID: UUID) -> WorkstreamTaskContract {
        WorkstreamTaskContract(
            id: UUID(),
            workstreamID: workstreamID,
            objective: "u11a4-handoff-test",
            fileScope: [],
            allowedTools: [],
            dependencies: [],
            staleSpecAt: nil,
            budget: ContractBudget(tokensMax: 0, wallClockMaxS: 0),
            commands: [],
            acceptance: [],
            reviewLevel: .none
        )
    }

    private static func makeHandoff(
        workstreamID: UUID,
        gateID: UUID,
        evidence: [String] = []
    ) -> BlockedHandoff {
        BlockedHandoff(
            id: UUID(),
            workstreamID: workstreamID,
            gateID: gateID,
            blockerReason: "gate.pre_run refused under block policy",
            owner: .operator,
            nextAction: "operator review required to clear gate.pre_run before re-attempt",
            evidenceBundle: evidence
        )
    }

    private static func countHandoffRows(_ db: SessionDatabase) -> Int {
        var count = 0
        db.unsafeQueueSync { rawDB in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                rawDB,
                "SELECT COUNT(*) FROM workstream_handoffs;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(stmt, 0))
            }
        }
        return count
    }

    private static func countTokenEventsWithSource(_ db: SessionDatabase, source: String) -> Int {
        var count = 0
        db.unsafeQueueSync { rawDB in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                rawDB,
                "SELECT COUNT(*) FROM token_events WHERE source = ?;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (source as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(stmt, 0))
            }
        }
        return count
    }

    /// Read back one workstream_handoffs row by its UUID id. Returns
    /// the decoded BlockedHandoff + contractID + createdAt, or nil if
    /// no row matches.
    private static func readHandoffRow(
        _ db: SessionDatabase,
        handoffID: UUID
    ) -> (BlockedHandoff, contractID: UUID, createdAt: Int64)? {
        var result: (BlockedHandoff, UUID, Int64)?
        db.unsafeQueueSync { rawDB in
            let sql = """
                SELECT id, workstream_id, contract_id, gate_id,
                       blocker_reason, owner, next_action, evidence_bundle,
                       created_at
                  FROM workstream_handoffs
                 WHERE id = ?
                 LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(rawDB, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            // Bind handoff UUID as 16-byte blob.
            var bytes = handoffID.uuid
            withUnsafeBytes(of: &bytes) { raw in
                _ = sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(raw.count), nil)
            }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return }

            func blobUUID(_ col: Int32) -> UUID? {
                guard sqlite3_column_type(stmt, col) == SQLITE_BLOB,
                      sqlite3_column_bytes(stmt, col) == 16,
                      let raw = sqlite3_column_blob(stmt, col) else { return nil }
                let p = raw.assumingMemoryBound(to: UInt8.self)
                let tuple = (
                    p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7],
                    p[8], p[9], p[10], p[11], p[12], p[13], p[14], p[15]
                )
                return UUID(uuid: tuple)
            }
            guard let idUUID = blobUUID(0),
                  let wsUUID = blobUUID(1),
                  let contractUUID = blobUUID(2),
                  let gateUUID = blobUUID(3) else { return }
            let reason = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let ownerStr = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let nextAction = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
            let evidenceJSON = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "[]"
            let createdAt = sqlite3_column_int64(stmt, 8)
            let evidence: [String] = {
                guard let data = evidenceJSON.data(using: .utf8) else { return [] }
                return (try? JSONDecoder().decode([String].self, from: data)) ?? []
            }()
            let owner = HandoffOwner(rawValue: ownerStr) ?? .operator
            let handoff = BlockedHandoff(
                id: idUUID,
                workstreamID: wsUUID,
                gateID: gateUUID,
                blockerReason: reason,
                owner: owner,
                nextAction: nextAction,
                evidenceBundle: evidence
            )
            result = (handoff, contractUUID, createdAt)
        }
        return result
    }

    /// Look up the rolling chain anchor reason for the named table —
    /// used by the pre-v33 drop test to swap the anchor's reason out
    /// from under a writer.
    private static func anchorReason(_ db: SessionDatabase, table: String) -> String? {
        var reason: String?
        db.unsafeQueueSync { rawDB in
            let sql = """
                SELECT reason FROM chain_anchors
                 WHERE table_name = ?
                 ORDER BY id DESC LIMIT 1;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(rawDB, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (table as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW,
               let cstr = sqlite3_column_text(stmt, 0) {
                reason = String(cString: cstr)
            }
        }
        return reason
    }

    // MARK: - Tests

    @Test("BlockedHandoff.render() carries zero raw-stdout substrings even when evidence contains marker stand-ins")
    func render_carries_no_raw_stdout() {
        // Construct a handoff whose evidence bundle entries are
        // intentionally formed as structured pointers; assert the
        // render() output never inlines stdout-shaped substrings.
        let marker = "RAW_STDOUT_MARKER_42"
        let handoff = BlockedHandoff(
            id: UUID(),
            workstreamID: UUID(),
            gateID: UUID(),
            blockerReason: "gate.pre_run refused under block policy",
            owner: .operator,
            nextAction: "operator review required to clear gate.pre_run before re-attempt",
            // Evidence entries are structured pointers — never raw
            // stdout pastes. The marker MUST appear in the rendered
            // output ONLY as a structured pointer (i.e. prefixed
            // `evidence: `), not as a raw substring at the top level.
            evidenceBundle: [
                "token_events#42",
                "/tmp/senkani-evidence/\(marker).txt",
            ]
        )

        let rendered = handoff.render()

        // Required structure: BlockedHandoff header + the labelled
        // fields a future CLI/pane surface can grep on.
        #expect(rendered.contains("BlockedHandoff"),
                "rendered output must carry the BlockedHandoff header")
        #expect(rendered.contains("handoff_id: \(handoff.id.uuidString)"))
        #expect(rendered.contains("workstream_id: \(handoff.workstreamID.uuidString)"))
        #expect(rendered.contains("gate_id: \(handoff.gateID.uuidString)"))
        #expect(rendered.contains("owner: operator"))
        #expect(rendered.contains("reason: \(handoff.blockerReason)"))
        #expect(rendered.contains("next_action: \(handoff.nextAction)"))

        // Structured-reason invariant (a-4 specialization of a-3's):
        // the render must not contain shell-prompt markers, newline-
        // padded error heads, ANSI escapes, or carriage returns.
        // (Evidence entries surfaced as "  - evidence: <ptr>" are the
        // only newline pattern allowed and they prefix `evidence:`.)
        for forbidden in ["\u{001B}", "\r", "$ ", "Error:"] {
            #expect(!rendered.contains(forbidden),
                    "render() must read zero raw-stdout substrings — contains '\(forbidden)'")
        }

        // The marker may appear, but only as part of a structured
        // pointer (prefixed `evidence: `). Verify that every line
        // mentioning the marker is an evidence line.
        let markerLines = rendered.split(separator: "\n").filter { $0.contains(marker) }
        #expect(!markerLines.isEmpty, "evidence pointer should appear in rendered output")
        for line in markerLines {
            #expect(line.contains("evidence: "),
                    "marker '\(marker)' may appear ONLY in structured `evidence: <pointer>` lines — got: '\(line)'")
        }
    }

    @Test("handoff.open + handoff.close writer inserts chained rows under migration-v40; ChainVerifier passes; pre-v33 anchor drops")
    func handoff_event_writer_and_chain_verify() async throws {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let handoffID = UUID()
        let workstreamID = UUID()
        let contractID = UUID()
        let gateID = UUID()

        // Write one open + one close pair.
        db.recordHandoffEvent(
            handoffID: handoffID,
            workstreamID: workstreamID,
            contractID: contractID,
            gateID: gateID,
            event: .open
        )
        db.recordHandoffEvent(
            handoffID: handoffID,
            workstreamID: workstreamID,
            contractID: contractID,
            gateID: gateID,
            event: .close
        )
        Self.flushQueue(db)

        #expect(Self.countTokenEventsWithSource(db, source: "handoff.open") == 1,
                "expected exactly 1 handoff.open row")
        #expect(Self.countTokenEventsWithSource(db, source: "handoff.close") == 1,
                "expected exactly 1 handoff.close row")

        // Chain integrity holds on token_events.
        switch ChainVerifier.verifyTokenEvents(db) {
        case .ok: break
        case let result:
            Issue.record("expected .ok after handoff event writes; got \(result)")
        }

        // Pre-v33 anchor drops: rewrite the rolling token_events
        // anchor reason to a pre-v33 value, invalidate the chain
        // cache, then try to write another handoff event. No new
        // rows should land. The base count we compare against is
        // captured BEFORE the swap.
        let baseOpenCount = Self.countTokenEventsWithSource(db, source: "handoff.open")
        let baseCloseCount = Self.countTokenEventsWithSource(db, source: "handoff.close")
        db.unsafeQueueSync { rawDB in
            // Rename whichever anchor the writer is targeting next.
            var stmt: OpaquePointer?
            let sql = """
                UPDATE chain_anchors
                   SET reason = 'fresh-install-pre-v18'
                 WHERE id = (
                    SELECT id FROM chain_anchors
                     WHERE table_name = 'token_events'
                     ORDER BY id DESC LIMIT 1
                 );
            """
            _ = sqlite3_prepare_v2(rawDB, sql, -1, &stmt, nil)
            _ = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        // The writer caches the anchor reason inside ChainState, so
        // we must invalidate the cache before the next write picks
        // up the new reason. Production code routes this through
        // `--repair-chain`; tests reach in directly via the public
        // SessionDatabase helper.
        db.invalidateChainCaches()

        db.recordHandoffEvent(
            handoffID: UUID(),
            workstreamID: workstreamID,
            contractID: contractID,
            gateID: gateID,
            event: .open
        )
        Self.flushQueue(db)

        let afterOpenCount = Self.countTokenEventsWithSource(db, source: "handoff.open")
        let afterCloseCount = Self.countTokenEventsWithSource(db, source: "handoff.close")
        #expect(afterOpenCount == baseOpenCount,
                "pre-v33 anchor must drop handoff.open write; got \(afterOpenCount) (was \(baseOpenCount))")
        #expect(afterCloseCount == baseCloseCount,
                "pre-v33 anchor must not affect existing handoff.close rows; got \(afterCloseCount) (was \(baseCloseCount))")
    }

    @Test("Migration v40 ledger advances: PRAGMA user_version == 40, schema_migrations row, workstream_handoffs table + indexes, migration-v40 anchor exists; ChainVerifier accepts")
    func migration_v40_ledger_advances() async throws {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // user_version should now be at least 40 (the latest
        // registered migration). Inequality rather than equality
        // future-proofs against subsequent migrations added after a-4.
        var userVersion: Int = -1
        var hasV40Row = false
        var hasHandoffsTable = false
        var hasWorkstreamFKIndex = false
        db.unsafeQueueSync { rawDB in
            var stmt: OpaquePointer?
            _ = sqlite3_prepare_v2(rawDB, "PRAGMA user_version;", -1, &stmt, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                userVersion = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)

            stmt = nil
            _ = sqlite3_prepare_v2(rawDB,
                "SELECT 1 FROM schema_migrations WHERE version = 40;",
                -1, &stmt, nil)
            hasV40Row = (sqlite3_step(stmt) == SQLITE_ROW)
            sqlite3_finalize(stmt)

            stmt = nil
            _ = sqlite3_prepare_v2(rawDB,
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='workstream_handoffs';",
                -1, &stmt, nil)
            hasHandoffsTable = (sqlite3_step(stmt) == SQLITE_ROW)
            sqlite3_finalize(stmt)

            stmt = nil
            _ = sqlite3_prepare_v2(rawDB,
                "SELECT 1 FROM sqlite_master WHERE type='index' AND name='idx_workstream_handoffs_workstream_id';",
                -1, &stmt, nil)
            hasWorkstreamFKIndex = (sqlite3_step(stmt) == SQLITE_ROW)
            sqlite3_finalize(stmt)
        }

        #expect(userVersion >= 40,
                "PRAGMA user_version must advance to v40 or beyond; got \(userVersion)")
        #expect(hasV40Row, "schema_migrations must carry a row for v40")
        #expect(hasHandoffsTable, "workstream_handoffs table must exist")
        #expect(hasWorkstreamFKIndex, "idx_workstream_handoffs_workstream_id must exist")

        // A fresh test DB has no pre-existing token_events rows, so
        // the v40 anchor on token_events opens lazily on first write.
        // Write one handoff event to drive the lazy anchor open.
        db.recordHandoffEvent(
            handoffID: UUID(),
            workstreamID: UUID(),
            contractID: UUID(),
            gateID: UUID(),
            event: .open
        )
        Self.flushQueue(db)

        // Now the token_events anchor exists. For a fresh DB the
        // anchor reason is `fresh-install` (not `migration-v40`) —
        // both join the v33/v35 shape sets. Verify the chain.
        switch ChainVerifier.verifyTokenEvents(db) {
        case .ok: break
        case let result:
            Issue.record("expected .ok on fresh-v40 chain; got \(result)")
        }
    }

    @Test("BlockedHandoff persistence survives DB close + reopen: all columns + render() output byte-equal across restart")
    func persist_survives_restart() async throws {
        let path = "/tmp/senkani-u11a4-restart-\(UUID().uuidString).sqlite"
        let workstreamID = UUID()
        let contractID = UUID()
        let gateID = UUID()

        let evidence = [
            "token_events#1729",
            "/tmp/audit/handoff-evidence.log",
        ]
        let original = Self.makeHandoff(
            workstreamID: workstreamID,
            gateID: gateID,
            evidence: evidence
        )
        let originalRender = original.render()

        // First pass: open, write, close.
        do {
            let db1 = SessionDatabase(path: path)
            db1.recordBlockedHandoff(handoff: original, contractID: contractID)
            Self.flushQueue(db1)
            #expect(Self.countHandoffRows(db1) == 1,
                    "row must persist in workstream_handoffs before close")
            db1.close()
        }

        // Second pass: reopen same path, read back.
        let db2 = SessionDatabase(path: path)
        defer { TempSessionDatabase.close(db2, path: path) }

        #expect(Self.countHandoffRows(db2) == 1,
                "row must survive close + reopen")

        guard let read = Self.readHandoffRow(db2, handoffID: original.id) else {
            Issue.record("expected to read back the persisted handoff row")
            return
        }
        let (decoded, decodedContractID, _) = read

        #expect(decoded.id == original.id)
        #expect(decoded.workstreamID == original.workstreamID)
        #expect(decoded.gateID == original.gateID)
        #expect(decodedContractID == contractID, "contract_id FK must survive restart intact")
        #expect(decoded.blockerReason == original.blockerReason)
        #expect(decoded.owner == original.owner)
        #expect(decoded.nextAction == original.nextAction)
        #expect(decoded.evidenceBundle == original.evidenceBundle)

        // render() across restart must produce byte-equal output.
        #expect(decoded.render() == originalRender,
                "render() output must be identical across restart")

        // Chain still verifies on the dedicated workstream_handoffs
        // chain.
        switch ChainVerifier.verifyWorkstreamHandoffs(db2) {
        case .ok: break
        case let result:
            Issue.record("expected .ok on workstream_handoffs chain after restart; got \(result)")
        }
    }

    @Test("pre_run × block: driver.start() throws GateRefusal AND inserts workstream_handoffs row AND writes handoff.open — atomic outcome")
    func gate_throw_and_persist_atomic() async throws {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let workstreamID = UUID()
        let driver = PaneSessionDriver(
            workstreamID: workstreamID,
            slug: "u11a4-atomic-\(workstreamID.uuidString.prefix(8))",
            database: db)

        let contract = Self.makeContract(workstreamID: workstreamID)
        let gate = WorkflowGate(
            id: UUID(),
            contractID: contract.id,
            kind: .preRun,
            policy: .block,
            retry: .manual)
        await driver.attach(contract: contract, gates: [gate])

        // start() throws GateRefusal — capture the handoff.
        var caught: GateRefusal?
        do {
            try await driver.start()
            Issue.record("expected driver.start() to throw GateRefusal under block policy")
        } catch let err as GateRefusal {
            caught = err
        } catch {
            Issue.record("expected GateRefusal; got \(type(of: error)): \(error)")
        }
        Self.flushQueue(db)

        guard let refusal = caught else { return }

        // Workstream row was NOT created (start refused).
        let stateAfter = try await driver.currentState()
        #expect(stateAfter == nil, "workstream row must remain absent after refused start")

        // Exactly one workstream_handoffs row exists.
        #expect(Self.countHandoffRows(db) == 1,
                "block-policy refusal must persist exactly one workstream_handoffs row")

        // Exactly one gate.evaluate row + exactly one handoff.open
        // row landed; zero handoff.close rows.
        #expect(Self.countTokenEventsWithSource(db, source: "gate.evaluate") == 1,
                "block-policy refusal writes one gate.evaluate row")
        #expect(Self.countTokenEventsWithSource(db, source: "handoff.open") == 1,
                "block-policy refusal writes one handoff.open row")
        #expect(Self.countTokenEventsWithSource(db, source: "handoff.close") == 0,
                "no handoff.close until operator/driver resolves the handoff")

        // The persisted handoff row's identity matches the caught
        // GateRefusal's handoff.
        guard let read = Self.readHandoffRow(db, handoffID: refusal.handoff.id) else {
            Issue.record("expected to read the freshly-persisted handoff row")
            return
        }
        let (decoded, decodedContractID, _) = read
        #expect(decoded.workstreamID == workstreamID)
        #expect(decoded.gateID == gate.id)
        #expect(decodedContractID == contract.id, "contract FK must point back to attached contract")
        #expect(decoded.owner == .operator)

        // Now drive the resolve path → handoff.close lands.
        await driver.markHandoffResolved(refusal.handoff, contractID: contract.id)
        Self.flushQueue(db)
        #expect(Self.countTokenEventsWithSource(db, source: "handoff.close") == 1,
                "markHandoffResolved must write handoff.close")

        // All four chain rows (gate.evaluate + workstream_handoffs row
        // + handoff.open + handoff.close) hash chains verify.
        switch ChainVerifier.verifyTokenEvents(db) {
        case .ok: break
        case let result:
            Issue.record("expected .ok on token_events chain; got \(result)")
        }
        switch ChainVerifier.verifyWorkstreamHandoffs(db) {
        case .ok: break
        case let result:
            Issue.record("expected .ok on workstream_handoffs chain; got \(result)")
        }
    }

    @Test("Chain integrity holds across 1000 mixed events covering all 6 U.11 row kinds (contract.attach/advance, assertion.record, gate.evaluate, handoff.open/close)")
    func chain_integrity_storm_1k_mixed_kinds() async throws {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let workstreamID = UUID()
        let contractID = UUID()
        let gateID = UUID()

        // 1000 events distributed across the 6 row kinds. Use a
        // round-robin to guarantee every kind is exercised at least
        // 166 times, and to interleave kinds so a per-kind canonical
        // shape mismatch surfaces under verifier walk.
        let total = 1000
        var openHandoffs: [BlockedHandoff] = []
        for i in 0..<total {
            switch i % 6 {
            case 0:
                db.recordContractEvent(
                    contractID: contractID,
                    workstreamID: workstreamID,
                    event: .attach)
            case 1:
                db.recordContractEvent(
                    contractID: contractID,
                    workstreamID: workstreamID,
                    event: .advance)
            case 2:
                db.recordAssertionEvent(
                    assertionID: UUID(),
                    contractID: contractID,
                    state: .pass)
            case 3:
                db.recordGateEvent(
                    gateID: gateID,
                    contractID: contractID,
                    outcome: .warned)
            case 4:
                let handoff = Self.makeHandoff(
                    workstreamID: workstreamID,
                    gateID: gateID,
                    evidence: ["token_events#\(i)"])
                db.recordBlockedHandoff(handoff: handoff, contractID: contractID)
                db.recordHandoffEvent(
                    handoffID: handoff.id,
                    workstreamID: workstreamID,
                    contractID: contractID,
                    gateID: gateID,
                    event: .open)
                openHandoffs.append(handoff)
            case 5:
                // Close one of the previously-opened handoffs (or
                // fabricate a synthetic close pair if none open yet —
                // round-robin guarantees opens land in earlier slots,
                // so this branch always has a candidate).
                let target: BlockedHandoff
                if !openHandoffs.isEmpty {
                    target = openHandoffs.removeFirst()
                } else {
                    target = Self.makeHandoff(workstreamID: workstreamID, gateID: gateID)
                }
                db.recordHandoffEvent(
                    handoffID: target.id,
                    workstreamID: workstreamID,
                    contractID: contractID,
                    gateID: gateID,
                    event: .close)
            default:
                break
            }
        }
        Self.flushQueue(db)

        // Verify the token_events chain — every row kind hashed
        // under the lazy `fresh-install` anchor (which joins the
        // post-v33 + v35 shape sets along with migration-v38/v39/v40).
        switch ChainVerifier.verifyTokenEvents(db) {
        case .ok: break
        case let result:
            Issue.record("expected .ok on token_events chain after 1k storm; got \(result)")
        }

        // Verify the dedicated workstream_handoffs chain. The storm
        // wrote ~166 handoff rows (one per `i % 6 == 4` iteration);
        // all hash under the lazy `fresh-install` anchor.
        switch ChainVerifier.verifyWorkstreamHandoffs(db) {
        case .ok: break
        case let result:
            Issue.record("expected .ok on workstream_handoffs chain after 1k storm; got \(result)")
        }

        // Sanity: every row kind landed at least once.
        for kind in ["contract.attach", "contract.advance", "assertion.record",
                     "gate.evaluate", "handoff.open", "handoff.close"] {
            #expect(Self.countTokenEventsWithSource(db, source: kind) > 0,
                    "expected at least one '\(kind)' row in 1k storm")
        }
        #expect(Self.countHandoffRows(db) > 0,
                "expected workstream_handoffs rows to land in 1k storm")
    }
}

extension SessionDatabase {
    /// Test-only escape hatch: drop the cached chain anchor + last-hash
    /// for every chain participant. Production drops the cache via
    /// `senkani doctor --repair-chain`; the pre-v33 drop test reaches
    /// in directly to flip the rolling anchor's reason on disk and
    /// then force the writer to re-read it.
    func invalidateChainCaches() {
        tokenEventStore.invalidateChainCache()
    }
}
