import Testing
import Foundation
import Dispatch
@testable import Core

/// U.9c-2 — production-grade lease/ack semantics on top of the U.9a
/// fixture-level queue: fenced lease renewal, ack-on-commit atomicity,
/// dead-lease reclaim, and the anti-double-delivery / anti-double-ack
/// guarantees. All timing is `now`-injectable — no wall clock, no
/// sleeps, so the suite is deterministic under parallel load.
@Suite("U.9c-2 — Queue-worker lease/ack production semantics")
struct SessionWorkQueueLeaseAckTests {

    private func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-u9c2-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    // MARK: - Lease renewal (fenced)

    @Test("renewLease before expiry extends lease_expires_at and preserves ownership")
    func renewBeforeExpiryExtendsAndKeepsOwnership() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }
        let store: SessionWorkQueueStore = db.sessionWorkQueueStore

        let id = store.enqueue(kind: "renew_kind")
        db.flushWrites()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let leased = store.lease(owner: "w", leaseTtl: 10, now: t0)   // expires t0+10
        #expect(leased.count == 1)
        #expect(leased[0].leaseExpiresAt == t0.addingTimeInterval(10))

        // Renew at 50% of TTL with a fresh 10s window.
        let t5 = t0.addingTimeInterval(5)
        let result = store.renewLease(id: id, owner: "w", leaseTtl: 10, now: t5)
        #expect(result == .renewed(newExpiry: t5.addingTimeInterval(10)))

        // Ownership preserved: a *different* worker cannot re-lease (row
        // is still processing under "w"), and the original owner can ack.
        let t9 = t0.addingTimeInterval(9)
        #expect(store.lease(owner: "intruder", now: t9).isEmpty)
        #expect(store.ack(id: id, owner: "w", now: t9) == true)
    }

    @Test("renewLease after expiry fails .expired and does NOT resurrect the row")
    func renewAfterExpiryFailsCleanly() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }
        let store: SessionWorkQueueStore = db.sessionWorkQueueStore

        let id = store.enqueue(kind: "renew_expired")
        db.flushWrites()
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        #expect(store.lease(owner: "w", leaseTtl: 5, now: t0).count == 1)   // expires t0+5

        // Renew at t0+10 — already 5s past expiry. Must NOT resurrect.
        let tLate = t0.addingTimeInterval(10)
        #expect(store.renewLease(id: id, owner: "w", leaseTtl: 5, now: tLate) == .expired)

        // The reaper still reclaims it (renewal did not extend the TTL).
        #expect(store.reapExpiredLeases(now: tLate) == 1)
        let recovered = store.lease(owner: "fresh", leaseTtl: 5, now: tLate)
        #expect(recovered.count == 1)
        #expect(recovered[0].id == id)
    }

    @Test("renewLease from a non-owner is .notHeld and a no-op")
    func renewWrongOwnerNotHeld() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }
        let store: SessionWorkQueueStore = db.sessionWorkQueueStore

        let id = store.enqueue(kind: "renew_owner")
        db.flushWrites()
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        #expect(store.lease(owner: "owner-a", leaseTtl: 60, now: t0).count == 1)

        #expect(store.renewLease(id: id, owner: "imposter", leaseTtl: 60, now: t0.addingTimeInterval(1)) == .notHeld)
        // A renew on an unknown row id is also .notHeld.
        #expect(store.renewLease(id: 999_999, owner: "owner-a", now: t0) == .notHeld)
        // Real owner can still renew — the imposter attempt changed nothing.
        #expect(store.renewLease(id: id, owner: "owner-a", leaseTtl: 60, now: t0.addingTimeInterval(1)) != .notHeld)
    }

    @Test("heartbeat no longer resurrects an expired-but-unreaped lease")
    func heartbeatDoesNotResurrectExpired() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }
        let store: SessionWorkQueueStore = db.sessionWorkQueueStore

        let id = store.enqueue(kind: "hb_fence")
        db.flushWrites()
        let t0 = Date(timeIntervalSince1970: 4_000_000)
        #expect(store.lease(owner: "w", leaseTtl: 5, now: t0).count == 1)   // expires t0+5

        // Row is expired at t0+8 but the reaper has NOT run yet, so it is
        // still `state='processing'`. The old heartbeat would resurrect
        // it; the fenced one must refuse.
        #expect(store.heartbeat(id: id, owner: "w", leaseTtl: 5, now: t0.addingTimeInterval(8)) == false)
        // And it is still reclaimable — heartbeat did not push the TTL out.
        #expect(store.reapExpiredLeases(now: t0.addingTimeInterval(8)) == 1)
    }

    // MARK: - Ack-on-commit atomicity

    @Test("ackWorkOnCommit persists the work effect and the ack atomically")
    func ackOnCommitHappyPath() throws {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }
        let store: SessionWorkQueueStore = db.sessionWorkQueueStore

        let id = store.enqueue(kind: "commit_kind")
        db.flushWrites()
        let t0 = Date(timeIntervalSince1970: 5_000_000)
        #expect(store.lease(owner: "w", leaseTtl: 60, now: t0).count == 1)

        // Work effect = append a canonical event to the stream.
        let outcome = try db.ackWorkOnCommit(id: id, owner: "w", resultSummary: "ok", now: t0.addingTimeInterval(1)) { tx in
            tx.appendEvent(sourceTable: "token_events", sourceId: 42, kind: "work_effect")
        }
        guard case .committed(let eventId) = outcome else {
            Issue.record("expected .committed, got \(outcome)")
            return
        }
        #expect(eventId > 0)
        db.flushWrites()

        // Both effects visible: row succeeded AND the stream event landed.
        #expect(store.diagnostics().succeeded == 1)
        #expect(db.sessionEventStreamStore.lag(consumerId: "validation") == 1)
    }

    @Test("ackWorkOnCommit rolls back the work effect when the body throws (no ack, row still processing)")
    func ackOnCommitBodyThrowsRollsBack() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }
        let store: SessionWorkQueueStore = db.sessionWorkQueueStore
        struct Boom: Error {}

        let id = store.enqueue(kind: "throw_kind")
        db.flushWrites()
        let t0 = Date(timeIntervalSince1970: 6_000_000)
        #expect(store.lease(owner: "w", leaseTtl: 60, now: t0).count == 1)

        var threw = false
        do {
            _ = try db.ackWorkOnCommit(id: id, owner: "w", now: t0.addingTimeInterval(1)) { tx in
                _ = tx.appendEvent(sourceTable: "token_events", sourceId: 7, kind: "doomed")
                throw Boom()
            }
        } catch is Boom {
            threw = true
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(threw)
        db.flushWrites()

        // Neither the effect nor the ack persisted; the row is re-leasable.
        #expect(db.sessionEventStreamStore.lag(consumerId: "validation") == 0)
        let diag = store.diagnostics()
        #expect(diag.succeeded == 0)
        #expect(diag.processing == 1, "row stays processing — re-leasable after its lease expires")
    }

    @Test("ackWorkOnCommit returns .leaseLost (no effect) when the lease was reclaimed — no double-delivery")
    func ackOnCommitLeaseLostAfterReclaim() throws {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }
        let store: SessionWorkQueueStore = db.sessionWorkQueueStore

        let id = store.enqueue(kind: "reclaim_kind")
        db.flushWrites()
        let t0 = Date(timeIntervalSince1970: 7_000_000)
        #expect(store.lease(owner: "slow", leaseTtl: 5, now: t0).count == 1)

        // Slow worker stalls past its TTL; the reaper reclaims the row and
        // a fresh worker re-leases it.
        let tExpired = t0.addingTimeInterval(10)
        #expect(store.reapExpiredLeases(now: tExpired) == 1)
        #expect(store.lease(owner: "fast", leaseTtl: 60, now: tExpired).count == 1)

        // The stale slow worker now tries to ack-on-commit. It no longer
        // holds the lease → .leaseLost, and its effect must NOT persist.
        let outcome = try db.ackWorkOnCommit(id: id, owner: "slow", now: tExpired.addingTimeInterval(1)) { tx in
            tx.appendEvent(sourceTable: "token_events", sourceId: 99, kind: "stale_effect")
        }
        guard case .leaseLost = outcome else {
            Issue.record("expected .leaseLost, got \(outcome)")
            return
        }
        db.flushWrites()

        // Row is still held by "fast" (processing), and the stale effect
        // was rolled back.
        #expect(db.sessionEventStreamStore.lag(consumerId: "validation") == 0)
        let diag = store.diagnostics()
        #expect(diag.processing == 1)
        #expect(diag.succeeded == 0)
        // "fast" can still complete the work exactly once.
        #expect(store.ack(id: id, owner: "fast", now: tExpired.addingTimeInterval(2)) == true)
    }

    @Test("a second ackWorkOnCommit is a detectable .leaseLost no-op — no double-ack, no duplicated effect")
    func ackOnCommitNoDoubleAck() throws {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }
        let store: SessionWorkQueueStore = db.sessionWorkQueueStore

        let id = store.enqueue(kind: "double_ack")
        db.flushWrites()
        let t0 = Date(timeIntervalSince1970: 8_000_000)
        #expect(store.lease(owner: "w", leaseTtl: 60, now: t0).count == 1)

        // First ack commits effect + ack.
        let first = try db.ackWorkOnCommit(id: id, owner: "w", now: t0.addingTimeInterval(1)) { tx in
            tx.appendEvent(sourceTable: "token_events", sourceId: 1, kind: "effect_once")
        }
        guard case .committed = first else { Issue.record("first ack must commit"); return }
        db.flushWrites()
        #expect(db.sessionEventStreamStore.lag(consumerId: "validation") == 1)

        // Second ack of the now-succeeded row: detectable no-op, and its
        // effect is rolled back (no duplicate stream event).
        let second = try db.ackWorkOnCommit(id: id, owner: "w", now: t0.addingTimeInterval(2)) { tx in
            tx.appendEvent(sourceTable: "token_events", sourceId: 2, kind: "effect_twice")
        }
        guard case .leaseLost = second else { Issue.record("second ack must be .leaseLost"); return }
        db.flushWrites()

        #expect(db.sessionEventStreamStore.lag(consumerId: "validation") == 1, "effect applied exactly once")
        #expect(store.diagnostics().succeeded == 1)
    }

    // MARK: - Dead-lease reclaim (race + fence)

    @Test("concurrent reclaim of the same expired lease — exactly one reaper wins")
    func concurrentReclaimExactlyOneWinner() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }
        let store: SessionWorkQueueStore = db.sessionWorkQueueStore

        let id = store.enqueue(kind: "race_kind")
        db.flushWrites()
        let t0 = Date(timeIntervalSince1970: 9_000_000)
        #expect(store.lease(owner: "crashed", leaseTtl: 5, now: t0).count == 1)

        // Two reapers fire concurrently at the same post-expiry instant.
        // The serial-queue discipline serialises them; exactly one flips
        // processing → pending, so the reaped counts sum to 1.
        let tExpired = t0.addingTimeInterval(10)
        let counts = UnsafeMutableBufferPointer<Int>.allocate(capacity: 2)
        counts.initialize(repeating: 0)
        defer { counts.deallocate() }
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            counts[i] = store.reapExpiredLeases(now: tExpired)
        }
        #expect(counts[0] + counts[1] == 1, "exactly one reclaim wins; the other is a no-op")

        // And the row is re-leasable exactly once afterwards.
        _ = id
        #expect(store.lease(owner: "fresh", leaseTtl: 5, now: tExpired).count == 1)
        #expect(store.lease(owner: "fresh2", leaseTtl: 5, now: tExpired).isEmpty)
    }

    @Test("a renewal-fenced live worker is never raced into double-delivery by the reaper")
    func renewalFencesReclaim() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }
        let store: SessionWorkQueueStore = db.sessionWorkQueueStore

        let idLive = store.enqueue(kind: "live_kind")
        let idCrashed = store.enqueue(kind: "crashed_kind")
        db.flushWrites()
        let t0 = Date(timeIntervalSince1970: 10_000_000)
        #expect(store.lease(kinds: ["live_kind"], owner: "live", leaseTtl: 10, now: t0).count == 1)     // expires t0+10
        #expect(store.lease(kinds: ["crashed_kind"], owner: "crashed", leaseTtl: 10, now: t0).count == 1)

        // The live worker renews at 50% TTL → new expiry t5+10 = t0+15.
        #expect(store.renewLease(id: idLive, owner: "live", leaseTtl: 10, now: t0.addingTimeInterval(5)) == .renewed(newExpiry: t0.addingTimeInterval(15)))

        // Reaper runs at t0+12: the crashed lease (expired at t0+10) is
        // reclaimed; the renewed live lease (expires t0+15) is fenced out.
        #expect(store.reapExpiredLeases(now: t0.addingTimeInterval(12)) == 1)
        let diag = store.diagnostics(now: t0.addingTimeInterval(12))
        #expect(diag.pending == 1, "only the crashed row returned to pending")
        #expect(diag.processing == 1, "the renewed live lease stays held")

        // The live worker can still ack — it was never raced.
        #expect(store.ack(id: idLive, owner: "live", now: t0.addingTimeInterval(13)) == true)
    }
}
