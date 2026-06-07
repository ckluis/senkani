import Testing
import Foundation
import SQLite3
@testable import Core

/// Phase V.17c acceptance tests for the thread-handoff guardrails.
///
/// Covers the four acceptance sections from
/// `phase-v17c-thread-handoff-guardrails`:
///   1. Handoff-block predicate over `provider_runtime_event`:
///      importable ONLY when the thread's last event is
///      `.turnCompleted`; pending approval / user-input / tool-call /
///      aborted / no-events all block with a descriptive reason.
///   2. Audit-row plumbing: a dedicated `thread_handoff_event` chained
///      table (migration v43) captures pre/post event counts on every
///      accepted handoff.
///   3. T.5 chain integrity holds across a 100-row write storm, verified
///      via `ChainVerifier.verifyThreadHandoffs` + `verifyAll`.
///   4. Operator override: a force-import past a BLOCKED predicate must
///      supply a non-empty justification → stored in `override_reason`;
///      an override without one is REJECTED (no row written). A normal
///      accepted handoff has `override_reason = NULL`. Double-handoff is
///      idempotent via a `(thread_id, to_provider)` dedup index.
@Suite("ThreadHandoffGuardrails (V.17c)")
struct ThreadHandoffGuardrailsTests {

    // MARK: - Helpers

    private static func tempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-v17c-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    /// Insert one provider runtime event for `threadID` with the given
    /// type at a monotonic `observedAt` (so the last-event read is
    /// deterministic). Each call gets a fresh `rawPayloadHash`.
    @discardableResult
    private static func insert(
        _ db: SessionDatabase,
        threadID: String,
        type: ProviderRuntimeEvent.EventType,
        observedAt: Date,
        providerID: String = "codex"
    ) -> ProviderRuntimeEventStore.InsertOutcome {
        let event = ProviderRuntimeEvent(
            providerID: providerID,
            sessionID: "sess-\(threadID)",
            threadID: threadID,
            turnID: "turn-1",
            pane: "kb",
            type: type,
            observedAt: observedAt,
            rawPayloadHash: UUID().uuidString
        )
        return db.providerRuntimeEventStore.insert(event: event)
    }

    /// Build a stable thread that ends on `.turnCompleted`, returning the
    /// guard ready to query it.
    private static func stableThread(
        _ db: SessionDatabase,
        threadID: String,
        providerID: String = "codex"
    ) -> ThreadHandoffGuard {
        let base = Date(timeIntervalSince1970: 1_900_000_000)
        insert(db, threadID: threadID, type: .messageStarted,   observedAt: base.addingTimeInterval(0), providerID: providerID)
        insert(db, threadID: threadID, type: .messageDelta,     observedAt: base.addingTimeInterval(1), providerID: providerID)
        insert(db, threadID: threadID, type: .toolCallStarted,  observedAt: base.addingTimeInterval(2), providerID: providerID)
        insert(db, threadID: threadID, type: .toolCallFinished, observedAt: base.addingTimeInterval(3), providerID: providerID)
        insert(db, threadID: threadID, type: .turnCompleted,    observedAt: base.addingTimeInterval(4), providerID: providerID)
        return ThreadHandoffGuard(store: db.providerRuntimeEventStore)
    }

    // MARK: - §1 predicate: importable on turnCompleted

    @Test("predicate TRUE when the thread's last event is turnCompleted")
    func predicateImportableOnTurnCompleted() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let guardian = Self.stableThread(db, threadID: "thread-complete")
        let decision = guardian.canImport(threadID: "thread-complete", providerID: "codex")
        #expect(decision.importable == true)
        #expect(decision.blockedReason == nil)
    }

    @Test("predicate stays TRUE across repeated reads (stable, no side effects)")
    func predicateStableAcrossReads() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let guardian = Self.stableThread(db, threadID: "thread-stable")
        for _ in 0..<5 {
            #expect(guardian.canImport(threadID: "thread-stable").importable == true)
        }
        // The predicate is a pure read — it must not have written a
        // handoff row as a side effect.
        #expect(db.threadHandoffCount() == 0)
    }

    // MARK: - §1 predicate: the three pending blocks + aborted + empty

    @Test("predicate FALSE for pending approval (last event approvalRequested)")
    func predicateBlocksPendingApproval() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let base = Date(timeIntervalSince1970: 1_900_000_100)
        Self.insert(db, threadID: "thread-approval", type: .messageStarted,    observedAt: base.addingTimeInterval(0))
        Self.insert(db, threadID: "thread-approval", type: .approvalRequested, observedAt: base.addingTimeInterval(1))
        let guardian = ThreadHandoffGuard(store: db.providerRuntimeEventStore)
        let decision = guardian.canImport(threadID: "thread-approval")
        #expect(decision.importable == false)
        #expect(decision.blockedReason == "pending approval")
    }

    @Test("predicate FALSE for pending user input (last event userInputRequested)")
    func predicateBlocksPendingUserInput() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let base = Date(timeIntervalSince1970: 1_900_000_200)
        Self.insert(db, threadID: "thread-input", type: .messageStarted,      observedAt: base.addingTimeInterval(0))
        Self.insert(db, threadID: "thread-input", type: .userInputRequested,  observedAt: base.addingTimeInterval(1))
        let guardian = ThreadHandoffGuard(store: db.providerRuntimeEventStore)
        let decision = guardian.canImport(threadID: "thread-input")
        #expect(decision.importable == false)
        #expect(decision.blockedReason == "pending user input")
    }

    @Test("predicate FALSE for pending tool call (last event toolCallStarted, no finish after)")
    func predicateBlocksPendingToolCall() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let base = Date(timeIntervalSince1970: 1_900_000_300)
        Self.insert(db, threadID: "thread-tool", type: .messageStarted,  observedAt: base.addingTimeInterval(0))
        Self.insert(db, threadID: "thread-tool", type: .toolCallStarted, observedAt: base.addingTimeInterval(1))
        let guardian = ThreadHandoffGuard(store: db.providerRuntimeEventStore)
        let decision = guardian.canImport(threadID: "thread-tool")
        #expect(decision.importable == false)
        #expect(decision.blockedReason == "pending tool call")
    }

    @Test("predicate FALSE for an aborted turn (last event turnAborted)")
    func predicateBlocksTurnAborted() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let base = Date(timeIntervalSince1970: 1_900_000_400)
        Self.insert(db, threadID: "thread-abort", type: .messageStarted, observedAt: base.addingTimeInterval(0))
        Self.insert(db, threadID: "thread-abort", type: .turnAborted,    observedAt: base.addingTimeInterval(1))
        let guardian = ThreadHandoffGuard(store: db.providerRuntimeEventStore)
        let decision = guardian.canImport(threadID: "thread-abort")
        #expect(decision.importable == false)
        #expect(decision.blockedReason == "turn aborted")
    }

    @Test("predicate FALSE for a thread with no events (no completed turn)")
    func predicateBlocksNoEvents() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let guardian = ThreadHandoffGuard(store: db.providerRuntimeEventStore)
        let decision = guardian.canImport(threadID: "thread-ghost")
        #expect(decision.importable == false)
        #expect(decision.blockedReason == "no completed turn")
    }

    // MARK: - §2 audit row written with correct pre/post event counts

    @Test("accepted handoff writes one audit row with correct pre/post event counts")
    func auditRowCapturesEventCounts() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // 5-event stable thread on the source provider.
        _ = Self.stableThread(db, threadID: "thread-import", providerID: "codex")
        let pre = db.providerRuntimeEventStore.eventCount(threadID: "thread-import")
        #expect(pre == 5)

        let outcome = db.recordThreadHandoff(ThreadHandoff(
            fromProvider: "codex",
            toProvider: "claude_code",
            threadID: "thread-import",
            acceptedBy: "operator",
            preHandoffEventCount: pre,
            postHandoffEventCount: pre  // no new events landed yet at accept time
        ))
        #expect(outcome == .recorded)
        #expect(db.threadHandoffCount() == 1)

        let row = db.latestThreadHandoff(threadID: "thread-import")
        #expect(row?.pre == 5)
        #expect(row?.post == 5)
        #expect(row?.overrideReason == nil, "a normal accepted handoff stores NULL override_reason")
    }

    // MARK: - §3 T.5 chain integrity across a 100-row write storm

    @Test("T.5 chain integrity holds across 100 handoff rows (verifyThreadHandoffs == .ok)")
    func chainIntegrityAcrossHundredRows() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let burst = 100
        for i in 0..<burst {
            let outcome = db.recordThreadHandoff(ThreadHandoff(
                fromProvider: "codex",
                toProvider: "claude_code",
                threadID: "thread-burst-\(i)",   // distinct thread → distinct dedup key
                acceptedBy: "operator",
                preHandoffEventCount: i,
                postHandoffEventCount: i + 1,
                overrideReason: (i % 7 == 0) ? "operator override \(i)" : nil
            ))
            #expect(outcome == .recorded, "row \(i) must land")
        }
        #expect(db.threadHandoffCount() == burst)

        // Standalone verifier == .ok
        let standalone = ChainVerifier.verifyThreadHandoffs(db)
        if case .ok = standalone {
            // pass — zero dropped links across the burst
        } else {
            Issue.record("verifyThreadHandoffs must be .ok after \(burst) rows, got \(standalone)")
        }

        // verifyAll (which `senkani doctor --verify-chain` walks) covers it too.
        let perTable = ChainVerifier.verifyAll(db)
        let aggregate = perTable["thread_handoff_event"]
        #expect(aggregate != nil, "verifyAll must include thread_handoff_event")
        if case .ok = aggregate {
            // pass
        } else {
            Issue.record("expected thread_handoff_event .ok in verifyAll, got \(String(describing: aggregate))")
        }
    }

    @Test("verifyThreadHandoffs catches a tampered row (chain is real, not faked)")
    func chainCatchesTamper() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        for i in 0..<5 {
            _ = db.recordThreadHandoff(ThreadHandoff(
                fromProvider: "codex", toProvider: "claude_code",
                threadID: "thread-tamper-\(i)", acceptedBy: "operator",
                preHandoffEventCount: i, postHandoffEventCount: i + 1))
        }
        // Mutate a payload column WITHOUT recomputing entry_hash — a
        // tamper. The verifier must name it broken.
        db.queue.sync {
            guard let h = db.db else { return }
            _ = sqlite3_exec(h,
                "UPDATE thread_handoff_event SET accepted_by = 'attacker' WHERE id = 3;",
                nil, nil, nil)
        }
        let result = ChainVerifier.verifyThreadHandoffs(db)
        if case .brokenAt(let table, _, _, _) = result {
            #expect(table == "thread_handoff_event")
        } else {
            Issue.record("expected .brokenAt after tamper, got \(result)")
        }
    }

    // MARK: - §4 operator override + dedup

    @Test("override WITH justification stores override_reason")
    func overrideWithReasonStored() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // Source thread is BLOCKED (last event = approvalRequested), so a
        // real import path would consult the predicate and require an
        // override reason.
        let base = Date(timeIntervalSince1970: 1_900_001_000)
        Self.insert(db, threadID: "thread-forced", type: .approvalRequested, observedAt: base)
        let guardian = ThreadHandoffGuard(store: db.providerRuntimeEventStore)
        #expect(guardian.canImport(threadID: "thread-forced").importable == false)

        let outcome = db.recordThreadHandoff(ThreadHandoff(
            fromProvider: "codex",
            toProvider: "claude_code",
            threadID: "thread-forced",
            acceptedBy: "operator",
            preHandoffEventCount: 1,
            postHandoffEventCount: 1,
            overrideReason: "operator accepts pending-approval risk for migration"
        ))
        #expect(outcome == .recorded)
        let row = db.latestThreadHandoff(threadID: "thread-forced")
        #expect(row?.overrideReason == "operator accepts pending-approval risk for migration")
    }

    @Test("override WITHOUT justification is REJECTED — no row written")
    func overrideWithoutReasonRejected() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // Empty string and whitespace-only are both invalid justifications.
        for badReason in ["", "   ", "\n\t "] {
            let outcome = db.recordThreadHandoff(ThreadHandoff(
                fromProvider: "codex",
                toProvider: "claude_code",
                threadID: "thread-noreason",
                acceptedBy: "operator",
                preHandoffEventCount: 0,
                postHandoffEventCount: 0,
                overrideReason: badReason
            ))
            #expect(outcome == .rejectedMissingOverrideReason, "reason=\(badReason.debugDescription) must reject")
        }
        #expect(db.threadHandoffCount() == 0, "a rejected override must never silently write a row")
    }

    @Test("double-handoff dedup: same thread into same target provider is idempotent")
    func doubleHandoffDedup() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let h = ThreadHandoff(
            fromProvider: "codex", toProvider: "claude_code",
            threadID: "thread-dup", acceptedBy: "operator",
            preHandoffEventCount: 3, postHandoffEventCount: 3)

        #expect(db.recordThreadHandoff(h) == .recorded)
        #expect(db.recordThreadHandoff(h) == .idempotencyHit, "second import of same thread→target is a dedup hit")
        #expect(db.threadHandoffCount() == 1, "dedup must not land a second row")
    }

    @Test("idempotency on retry preserves chain integrity (dedup hit does not advance the chain)")
    func idempotencyRetryKeepsChainOk() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let h = ThreadHandoff(
            fromProvider: "codex", toProvider: "claude_code",
            threadID: "thread-retry", acceptedBy: "operator",
            preHandoffEventCount: 2, postHandoffEventCount: 4)

        #expect(db.recordThreadHandoff(h) == .recorded)
        // Retry several times — each is a dedup hit.
        for _ in 0..<5 {
            #expect(db.recordThreadHandoff(h) == .idempotencyHit)
        }
        #expect(db.threadHandoffCount() == 1)

        // The chain must still verify cleanly — a dedup hit must not have
        // advanced or corrupted the chain.
        let result = ChainVerifier.verifyThreadHandoffs(db)
        if case .ok = result {
            // pass
        } else {
            Issue.record("chain must stay .ok after idempotent retries, got \(result)")
        }
    }

    @Test("the SAME thread may hand off to DIFFERENT target providers (dedup key includes to_provider)")
    func sameThreadDifferentTargetsBothLand() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        #expect(db.recordThreadHandoff(ThreadHandoff(
            fromProvider: "codex", toProvider: "claude_code",
            threadID: "thread-fanout", acceptedBy: "operator",
            preHandoffEventCount: 1, postHandoffEventCount: 1)) == .recorded)
        #expect(db.recordThreadHandoff(ThreadHandoff(
            fromProvider: "codex", toProvider: "gemini",
            threadID: "thread-fanout", acceptedBy: "operator",
            preHandoffEventCount: 1, postHandoffEventCount: 1)) == .recorded)

        #expect(db.threadHandoffCount() == 2)
        // Chain stays clean across the two distinct rows.
        if case .ok = ChainVerifier.verifyThreadHandoffs(db) {
            // pass
        } else {
            Issue.record("chain must verify .ok across two distinct-target rows")
        }
    }

    // MARK: - migration discipline

    @Test("migration v43 runs and creates thread_handoff_event with the chain columns")
    func migrationV43CreatesTable() {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        #expect(db.currentSchemaVersion() >= 43, "schema must reach v43")

        let cols = db.queue.sync { () -> Set<String> in
            guard let h = db.db else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(h, "PRAGMA table_info(thread_handoff_event);", -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 1) { out.insert(String(cString: c)) }
            }
            return out
        }
        let required: Set<String> = [
            "id", "created_at", "from_provider", "to_provider", "thread_id",
            "accepted_by", "pre_handoff_event_count", "post_handoff_event_count",
            "override_reason", "prev_hash", "entry_hash", "chain_anchor_id",
        ]
        #expect(required.isSubset(of: cols), "missing columns: \(required.subtracting(cols))")
    }
}
