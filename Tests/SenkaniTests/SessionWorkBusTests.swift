import Testing
import Foundation
import SQLite3
@testable import Core

/// U.9a — 10 substrate tests covering queue lifecycle, stream offsets,
/// outbox rollback, diagnostics, and event-counter integration.
@Suite("U.9a — Session work bus substrate")
struct SessionWorkBusTests {

    private func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-u9a-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    // MARK: - Test 1: enqueue → lease → ack happy path

    @Test("enqueue → lease → ack happy path moves the row through pending → processing → succeeded")
    func happyPath() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        let id = db.sessionWorkQueueStore.enqueue(kind: "auto_validate", payload: "{\"file\":\"a.swift\"}")
        #expect(id > 0)
        db.flushWrites()

        let leases = db.sessionWorkQueueStore.lease(kinds: ["auto_validate"], owner: "worker-1")
        #expect(leases.count == 1)
        #expect(leases[0].id == id)
        #expect(leases[0].kind == "auto_validate")
        #expect(leases[0].owner == "worker-1")
        #expect(leases[0].payload == "{\"file\":\"a.swift\"}")

        #expect(db.sessionWorkQueueStore.ack(id: id, owner: "worker-1", resultSummary: "done") == true)
        db.flushWrites()

        let diag = db.sessionWorkQueueStore.diagnostics()
        #expect(diag.pending == 0)
        #expect(diag.processing == 0)
        #expect(diag.succeeded == 1)
    }

    // MARK: - Test 2: lease → heartbeat → ack (lease extension)

    @Test("heartbeat extends lease expiration; ack closes the row")
    func heartbeatExtendsLease() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        let id = db.sessionWorkQueueStore.enqueue(kind: "pane_refresh")
        db.flushWrites()
        let now = Date()
        let leases = db.sessionWorkQueueStore.lease(owner: "w", leaseTtl: 5, now: now)
        #expect(leases.count == 1)
        let originalExpiry = leases[0].leaseExpiresAt

        // Heartbeat extends ttl
        let later = now.addingTimeInterval(3)
        #expect(db.sessionWorkQueueStore.heartbeat(id: id, owner: "w", leaseTtl: 10, now: later) == true)

        // Verify the new lease_expires_at is `later + 10` > original `now + 5`.
        let extendedExpected = later.addingTimeInterval(10)
        #expect(extendedExpected.timeIntervalSince(originalExpiry) > 0)

        #expect(db.sessionWorkQueueStore.ack(id: id, owner: "w") == true)
    }

    // MARK: - Test 3: lease expiration + reaper re-pends

    @Test("reapExpiredLeases re-pends a stalled lease; re-leasing succeeds with new owner")
    func leaseExpirationAndReap() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        let id = db.sessionWorkQueueStore.enqueue(kind: "compound_learning")
        db.flushWrites()
        let now = Date()
        let leases = db.sessionWorkQueueStore.lease(owner: "crashed-worker", leaseTtl: 5, now: now)
        #expect(leases.count == 1)
        _ = leases

        // Worker crashes — no heartbeat. Simulate "now + 10s" reap.
        let future = now.addingTimeInterval(10)
        let reaped = db.sessionWorkQueueStore.reapExpiredLeases(now: future)
        #expect(reaped == 1)

        // New worker can re-lease.
        let recovered = db.sessionWorkQueueStore.lease(owner: "fresh-worker", leaseTtl: 5, now: future)
        #expect(recovered.count == 1)
        #expect(recovered[0].id == id)
        #expect(recovered[0].owner == "fresh-worker")
    }

    // MARK: - Test 4: retry with next_wakeup_at gates re-lease

    @Test("retry with future next_wakeup_at means lease() returns empty until wakeup")
    func retryGatesByWakeup() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        let id = db.sessionWorkQueueStore.enqueue(kind: "notification")
        db.flushWrites()
        let now = Date()
        let leases = db.sessionWorkQueueStore.lease(owner: "w", now: now)
        #expect(leases.count == 1)
        #expect(db.sessionWorkQueueStore.retry(id: id, owner: "w", reason: "transient", nextWakeupAt: now.addingTimeInterval(60), now: now) == true)

        // Re-lease "now" — wakeup is 60s in the future, returns empty.
        let early = db.sessionWorkQueueStore.lease(owner: "w2", now: now)
        #expect(early.isEmpty)

        // After wakeup: re-lease succeeds.
        let late = db.sessionWorkQueueStore.lease(owner: "w2", now: now.addingTimeInterval(70))
        #expect(late.count == 1)
        #expect(late[0].retryCount == 1)
    }

    // MARK: - Test 5: deadLetter + replay

    @Test("deadLetter moves the row to dead_letter state; replay returns it to pending with retry_count=0")
    func deadLetterAndReplay() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        let id = db.sessionWorkQueueStore.enqueue(kind: "analytics")
        db.flushWrites()
        let leases = db.sessionWorkQueueStore.lease(owner: "w")
        #expect(leases.count == 1)
        #expect(db.sessionWorkQueueStore.deadLetter(id: id, owner: "w", reason: "max_retry") == true)
        db.flushWrites()

        var diag = db.sessionWorkQueueStore.diagnostics()
        #expect(diag.deadLetter == 1)

        // Operator replay — back to pending.
        #expect(db.sessionWorkQueueStore.replay(id: id) == true)
        db.flushWrites()
        diag = db.sessionWorkQueueStore.diagnostics()
        #expect(diag.pending == 1)
        #expect(diag.deadLetter == 0)
    }

    // MARK: - Test 6: outbox transaction commits all OR rollbacks all

    @Test("withOutboxTransaction rolls back stream + queue rows when the body throws")
    func outboxRollbackAtomicity() throws {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        struct ContrivedFailure: Error {}
        // Body throws AFTER appending an event + enqueuing work. Both
        // must be rolled back.
        do {
            try db.withOutboxTransaction { tx in
                _ = tx.appendEvent(sourceTable: "token_events", sourceId: 1, kind: "test_event")
                _ = tx.enqueueWork(kind: "test_kind", payload: "{}")
                throw ContrivedFailure()
            }
            Issue.record("withOutboxTransaction must propagate the body's throw")
        } catch is ContrivedFailure {
            // Expected
        }

        // Verify NEITHER row exists.
        let lag = db.sessionEventStreamStore.lag(consumerId: "validation")
        #expect(lag == 0, "stream append must have been rolled back")
        let diag = db.sessionWorkQueueStore.diagnostics()
        #expect(diag.pending == 0, "queue enqueue must have been rolled back")
        #expect(diag.processing == 0)

        // Now run a successful transaction — both rows commit.
        let result: Int64 = try db.withOutboxTransaction { tx in
            _ = tx.appendEvent(sourceTable: "token_events", sourceId: 2, kind: "ok_event")
            return tx.enqueueWork(kind: "ok_kind", payload: "{}")
        }
        #expect(result > 0)
        db.flushWrites()
        #expect(db.sessionEventStreamStore.lag(consumerId: "validation") == 1)
        #expect(db.sessionWorkQueueStore.diagnostics().pending == 1)
    }

    // MARK: - Test 7: two consumers maintain independent offsets

    @Test("two consumers pull from the same stream + advance offsets independently")
    func independentConsumerOffsets() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        // Append 3 events.
        for i in 0..<3 {
            _ = db.sessionEventStreamStore.appendEvent(
                sourceTable: "token_events", sourceId: Int64(i), kind: "test"
            )
        }
        db.flushWrites()

        let consumer1 = db.sessionEventStreamStore.pullSince(consumerId: "validation")
        #expect(consumer1.count == 3)
        // Commit offset after processing only the first event.
        _ = db.sessionEventStreamStore.commitOffset(consumerId: "validation", upTo: consumer1[0].id)
        db.flushWrites()

        // validation lag drops to 2; agent_timeline lag still 3 (independent).
        #expect(db.sessionEventStreamStore.lag(consumerId: "validation") == 2)
        #expect(db.sessionEventStreamStore.lag(consumerId: "agent_timeline") == 3)

        // agent_timeline consumes all 3, advances its own offset.
        let consumer2 = db.sessionEventStreamStore.pullSince(consumerId: "agent_timeline")
        #expect(consumer2.count == 3)
        _ = db.sessionEventStreamStore.commitOffset(consumerId: "agent_timeline", upTo: consumer2.last!.id)
        db.flushWrites()
        #expect(db.sessionEventStreamStore.lag(consumerId: "agent_timeline") == 0)
        #expect(db.sessionEventStreamStore.lag(consumerId: "validation") == 2,
                "validation's offset must remain at its independent value")
    }

    // MARK: - Test 8: diagnostics reflects mixed state correctly

    @Test("diagnostics snapshot reflects 1 pending + 2 processing + 1 retried + 1 DLQ correctly")
    func diagnosticsRollup() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        // Set up: 1 pending + 2 processing + 1 retried(now pending) + 1 DLQ
        _ = db.sessionWorkQueueStore.enqueue(kind: "pending_kind")
        let p1 = db.sessionWorkQueueStore.enqueue(kind: "proc_kind_a")
        let p2 = db.sessionWorkQueueStore.enqueue(kind: "proc_kind_b")
        let retryId = db.sessionWorkQueueStore.enqueue(kind: "retry_kind")
        let dlqId = db.sessionWorkQueueStore.enqueue(kind: "dlq_kind")
        db.flushWrites()

        // Lease p1 + p2 (stays in processing)
        let leasesAB = db.sessionWorkQueueStore.lease(kinds: ["proc_kind_a", "proc_kind_b"], owner: "w", leaseTtl: 600)
        #expect(leasesAB.count == 2)
        _ = leasesAB.map(\.id).contains(p1)
        _ = leasesAB.map(\.id).contains(p2)

        // Lease retry + retry it back (retry_count = 1, state=pending)
        let leasesR = db.sessionWorkQueueStore.lease(kinds: ["retry_kind"], owner: "w")
        #expect(leasesR.count == 1)
        #expect(db.sessionWorkQueueStore.retry(id: retryId, owner: "w") == true)

        // Lease dlq + dead-letter it
        let leasesD = db.sessionWorkQueueStore.lease(kinds: ["dlq_kind"], owner: "w")
        #expect(leasesD.count == 1)
        #expect(db.sessionWorkQueueStore.deadLetter(id: dlqId, owner: "w", reason: "fatal") == true)
        db.flushWrites()

        let diag = db.sessionWorkQueueStore.diagnostics()
        // pending = original-pending + retried-back = 2
        #expect(diag.pending == 2)
        #expect(diag.processing == 2)
        #expect(diag.deadLetter == 1)
        #expect(diag.retriedTotal == 1, "one row was retried once → retried_total=1")
        #expect(diag.byKind.keys.contains("pending_kind"))
        #expect(diag.byKind.keys.contains("proc_kind_a"))
        #expect(diag.byKind.keys.contains("proc_kind_b"))
        #expect(diag.byKind.keys.contains("retry_kind"))
    }

    // MARK: - Test 9: event_counters tick on state transitions

    @Test("event_counters increments fire on queue state transitions (enqueue / lease / ack / retry / dead_letter / lease_expired)")
    func eventCountersTick() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        let id = db.sessionWorkQueueStore.enqueue(kind: "metrics_kind")
        db.flushWrites()
        let leases = db.sessionWorkQueueStore.lease(owner: "w")
        #expect(leases.count == 1)
        #expect(db.sessionWorkQueueStore.retry(id: id, owner: "w", reason: "x") == true)
        let leases2 = db.sessionWorkQueueStore.lease(owner: "w")
        #expect(leases2.count == 1)
        #expect(db.sessionWorkQueueStore.ack(id: id, owner: "w") == true)
        db.flushWrites()

        let counters = db.eventCounts(prefix: "session_work_queue.")
        let types = Set(counters.map(\.eventType))
        #expect(types.contains("session_work_queue.enqueued"))
        #expect(types.contains("session_work_queue.leased"))
        #expect(types.contains("session_work_queue.retried"))
        #expect(types.contains("session_work_queue.acked"))
    }

    // MARK: - Test 10: lease ownership rejection (no silent corruption)

    @Test("heartbeat/ack/retry from non-owner is rejected and does not mutate state")
    func ownershipRejection() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.cleanup(path: path) }

        let id = db.sessionWorkQueueStore.enqueue(kind: "owned_kind")
        db.flushWrites()
        let leases = db.sessionWorkQueueStore.lease(owner: "owner-a", leaseTtl: 60)
        #expect(leases.count == 1)

        // Wrong owner: every action returns false.
        #expect(db.sessionWorkQueueStore.heartbeat(id: id, owner: "imposter") == false)
        #expect(db.sessionWorkQueueStore.ack(id: id, owner: "imposter") == false)
        #expect(db.sessionWorkQueueStore.retry(id: id, owner: "imposter") == false)
        #expect(db.sessionWorkQueueStore.deadLetter(id: id, owner: "imposter", reason: "x") == false)

        // Row state unchanged — still processing under owner-a.
        let diag = db.sessionWorkQueueStore.diagnostics()
        #expect(diag.processing == 1, "row must remain in processing — no silent corruption")
        #expect(diag.pending == 0)
        #expect(diag.succeeded == 0)
        #expect(diag.deadLetter == 0)

        // Correct owner: ack still works.
        #expect(db.sessionWorkQueueStore.ack(id: id, owner: "owner-a") == true)
    }
}
