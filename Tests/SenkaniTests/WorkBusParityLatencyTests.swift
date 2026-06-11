import Testing
import Foundation
@testable import CLI
@testable import Core

/// U.9b-3b leg 4 — the doctor latency sub-rows the u9b-3 spine deferred.
///
/// Pairing/timing derives from the `session_work_queue` rows the
/// dual-write legs already write (no new storage): the bus enqueue
/// happens synchronously at in-process-leg completion, so `created_at`
/// is the in-process leg's completion instant and a succeeded row's
/// `updated_at` (the terminal ack) is the bus leg's. All timing here is
/// fixture-driven via the injectable `at:` / `now:` parameters — no
/// wall-clock sleeps, no loop-timing asserts.
@Suite("U.9b-3b leg 4 — work-bus parity latency sub-rows")
struct WorkBusParityLatencyTests {

    private func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-u9b3b-leg4-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    // MARK: - Test 1: pairing/timing computation over an injected-timestamp fixture

    @Test("latency-delta p50/p95 + oldest-unmatched-pair age compute correctly over an injected-timestamp fixture")
    func parityTimingComputesOverFixture() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }
        let store: SessionWorkQueueStore = db.sessionWorkQueueStore
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // Five matched pairs: enqueue at t0 (the in-process leg's
        // completion instant), lease + ack at t0 + delta (the bus leg's
        // completion). Deltas: 1, 2, 3, 4, 10 seconds.
        for delta in [1.0, 2.0, 3.0, 4.0, 10.0] {
            let id = store.enqueue(kind: AutoValidateDualWrite.kind, at: t0)
            #expect(id > 0)
            let leases = store.lease(kinds: [AutoValidateDualWrite.kind], owner: "w", now: t0)
            #expect(leases.count == 1)
            #expect(store.ack(id: id, owner: "w", now: t0.addingTimeInterval(delta)))
        }

        // Two unmatched pairs (bus leg not yet complete): the OLDEST is a
        // pane_refresh row enqueued at t0+5; the other is a processing
        // auto_validate row enqueued at t0+20 (leased but never acked —
        // processing still counts as unmatched).
        #expect(store.enqueue(kind: PaneRefreshDualWrite.kind, at: t0.addingTimeInterval(5)) > 0)
        let procId = store.enqueue(kind: AutoValidateDualWrite.kind, at: t0.addingTimeInterval(20))
        #expect(procId > 0)
        let procLeases = store.lease(
            kinds: [AutoValidateDualWrite.kind], owner: "w2",
            now: t0.addingTimeInterval(20)
        )
        #expect(procLeases.map(\.id) == [procId])

        // A dead-letter row is terminal divergence — neither matched nor
        // unmatched (the queue line's dead_letter count owns it).
        let dlqId = store.enqueue(kind: AutoValidateDualWrite.kind, at: t0)
        let dlqLeases = store.lease(kinds: [AutoValidateDualWrite.kind], owner: "w3", now: t0)
        #expect(dlqLeases.map(\.id) == [dlqId])
        #expect(store.deadLetter(id: dlqId, owner: "w3", reason: "fixture", now: t0.addingTimeInterval(1)))

        // Rows of an unrelated kind are excluded by the kinds filter —
        // one succeeded with a huge delta, one ancient pending.
        let otherId = store.enqueue(kind: "other_kind", at: t0)
        let otherLeases = store.lease(kinds: ["other_kind"], owner: "w4", now: t0)
        #expect(otherLeases.map(\.id) == [otherId])
        #expect(store.ack(id: otherId, owner: "w4", now: t0.addingTimeInterval(9999)))
        #expect(store.enqueue(kind: "other_kind", at: t0.addingTimeInterval(-9999)) > 0)

        let timing = store.parityTiming(
            kinds: [AutoValidateDualWrite.kind, PaneRefreshDualWrite.kind],
            now: t0.addingTimeInterval(30)
        )
        #expect(timing.matchedDeltas.sorted() == [1.0, 2.0, 3.0, 4.0, 10.0])
        #expect(timing.percentile(50) == 3.0)
        #expect(timing.percentile(95) == 10.0)
        #expect(timing.unmatchedCount == 2)
        // Oldest unmatched = the pane_refresh row from t0+5, aged 25s at t0+30.
        #expect(timing.oldestUnmatchedAge == 25.0)

        // Empty-window edges: no matched pairs ⇒ percentiles nil; the
        // pure nearest-rank helper rejects out-of-range p.
        let empty = SessionWorkQueueStore.ParityTiming(
            matchedDeltas: [], unmatchedCount: 0, oldestUnmatchedAge: nil
        )
        #expect(empty.percentile(50) == nil)
        #expect(timing.percentile(0) == nil)
        #expect(timing.percentile(101) == nil)
    }

    // MARK: - Test 2: doctor surface renders the sub-rows, exit code stays 0

    @Test("doctor renders the latency sub-rows as informational pass lines — exit code stays 0")
    func doctorRendersSubRowsAsPass() {
        // Populated window: 3 matched pairs, 1 unmatched aged 42.5s.
        // Nearest-rank over [0.25, 2.0, 3.0]: p50 = 2.0, p95 = 3.0.
        let timing = SessionWorkQueueStore.ParityTiming(
            matchedDeltas: [0.25, 2.0, 3.0],
            unmatchedCount: 1,
            oldestUnmatchedAge: 42.5
        )
        let lines = Doctor.formatWorkBusLatencyLines(timing: timing)
        #expect(lines.count == 2)
        #expect(lines[0].1 == "work-bus latency-delta — matched_pairs: 3 | p50: 2.0s | p95: 3.0s")
        #expect(lines[1].1 == "work-bus oldest-unmatched-pair — unmatched: 1 | age: 42.5s")

        // Sub-second deltas render as milliseconds, not "0.0s".
        let subSecond = SessionWorkQueueStore.ParityTiming(
            matchedDeltas: [0.25], unmatchedCount: 0, oldestUnmatchedAge: nil
        )
        let subLines = Doctor.formatWorkBusLatencyLines(timing: subSecond)
        #expect(subLines[0].1 == "work-bus latency-delta — matched_pairs: 1 | p50: 250ms | p95: 250ms")
        #expect(subLines[1].1 == "work-bus oldest-unmatched-pair — unmatched: 0 | age: n/a")

        // Fresh-install / default-OFF posture: still renders, all n/a.
        let empty = SessionWorkQueueStore.ParityTiming(
            matchedDeltas: [], unmatchedCount: 0, oldestUnmatchedAge: nil
        )
        let emptyLines = Doctor.formatWorkBusLatencyLines(timing: empty)
        #expect(emptyLines[0].1 == "work-bus latency-delta — matched_pairs: 0 | p50: n/a | p95: n/a")
        #expect(emptyLines[1].1 == "work-bus oldest-unmatched-pair — unmatched: 0 | age: n/a")

        // INFORMATIONAL invariant: every line is `.pass` in every shape,
        // so `checkSessionWorkBus` only ever increments `results.passed`
        // — the doctor exit code stays 0 regardless of bus latency.
        for (status, message) in lines + subLines + emptyLines {
            guard case .pass = status else {
                Issue.record("latency sub-row must be .pass (informational), got \(status) for: \(message)")
                return
            }
        }
    }
}
