import Testing
import Foundation
@testable import Core

/// U.9c-1 — the FIRST production producer of `session_event_stream`.
///
/// Before this phase the stream mirror had ZERO production writers even with
/// `WorkBusConfig.dualWrite == true` (the U.9b dual-write path enqueues into
/// `session_work_queue`, bypassing the outbox). These tests pin the new
/// producer: `ValidationStore.insertValidationResultWithOutbox` routes the
/// canonical `validation_results` insert plus a paired stream row through
/// `SessionDatabase.withOutboxTransaction`, atomically, gated by `dualWrite`.
///
/// FLAKE-DISCIPLINE (Carmack R7/R8): the producer is pure-synchronous — it
/// runs on the caller's thread via `queue.sync`, no `Task.detached(.utility)`,
/// no second cooperative-pool hop. These tests drive the SYNCHRONOUS producer
/// + the synchronous `drainToHead`/`process` consumer seams directly; no
/// wall-clock or scheduler dependence.
@Suite("U.9c-1 — session_event_stream producer", .serialized)
struct ValidationEventStreamProducerTests {

    private static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-u9c1-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private static func streamRows(_ db: SessionDatabase) -> Int {
        db.sessionEventStreamStore.count(sourceTable: ValidationEventStreamProducer.sourceTable)
    }

    private static func producedCount(_ db: SessionDatabase, projectRoot: String) -> Int {
        db.flushWrites()
        return db.eventCounts(projectRoot: projectRoot)
            .first(where: { $0.eventType == ValidationEventStreamProducer.producedCounter })?.count ?? 0
    }

    // MARK: - Test 1: dualWrite=false is byte-identical to pre-U.9c

    @Test("dualWrite=false: the OFF path writes the canonical row and ZERO stream rows; content byte-identical to the outbox row")
    func dualWriteOffIsByteIdentical() {
        // OFF path — exactly what AutoValidateQueue calls when dualWrite is
        // false (the fire-and-forget insert, untouched by U.9c-1).
        let (offDB, offPath) = Self.makeTempDB()
        defer { TempSessionDatabase.close(offDB, path: offPath) }
        offDB.insertValidationResult(
            sessionId: "sid", filePath: "/tmp/a.swift", validatorName: "swiftc",
            category: "type", exitCode: 1, rawOutput: "err", advisory: "'a' undefined",
            durationMs: 10, outcome: "advisory", reason: nil
        )
        offDB.flushWrites()

        // Zero stream rows: the mirror stays empty on the OFF path.
        #expect(Self.streamRows(offDB) == 0, "dualWrite=false must write zero session_event_stream rows")
        #expect(Self.producedCount(offDB, projectRoot: "") == 0, "OFF must not emit the produced counter")
        let offRows = offDB.validationResults(sessionId: "sid")
        #expect(offRows.count == 1, "OFF path still writes the canonical row")

        // ON path — same logical inputs through the outbox producer.
        let (onDB, onPath) = Self.makeTempDB()
        defer { TempSessionDatabase.close(onDB, path: onPath) }
        _ = onDB.insertValidationResultWithOutbox(
            sessionId: "sid", filePath: "/tmp/a.swift", validatorName: "swiftc",
            category: "type", exitCode: 1, rawOutput: "err", advisory: "'a' undefined",
            durationMs: 10, projectRoot: nil, outcome: "advisory", reason: nil
        )
        let onRows = onDB.validationResults(sessionId: "sid")
        #expect(onRows.count == 1)

        // Canonical-row content unchanged: every semantic column matches the
        // OFF path (created_at is a per-call timestamp, excluded).
        let off = offRows[0], on = onRows[0]
        #expect(off.filePath == on.filePath)
        #expect(off.validatorName == on.validatorName)
        #expect(off.category == on.category)
        #expect(off.exitCode == on.exitCode)
        #expect(off.advisory == on.advisory)
        #expect(off.durationMs == on.durationMs)
        #expect(off.outcome == on.outcome)
        #expect(off.reason == on.reason)
    }

    // MARK: - Test 2: dualWrite=true — exactly one stream row per canonical row

    @Test("dualWrite=true: each canonical row lands with exactly one paired stream row (same sourceId), synchronously committed")
    func dualWriteOnPairsExactlyOne() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }
        let root = "/tmp/senkani-u9c1-on"

        let adv = db.insertValidationResultWithOutbox(
            sessionId: "sid", filePath: "/tmp/a.swift", validatorName: "swiftc",
            category: "type", exitCode: 1, rawOutput: "err", advisory: "'a' undefined",
            durationMs: 10, projectRoot: root, outcome: "advisory", reason: nil
        )
        let clean = db.insertValidationResultWithOutbox(
            sessionId: "sid", filePath: "/tmp/b.swift", validatorName: "swiftc",
            category: "type", exitCode: 0, rawOutput: nil, advisory: "",
            durationMs: 11, projectRoot: root, outcome: "clean", reason: nil
        )

        // Synchronous commit: the rows are visible WITHOUT flushWrites (the
        // outbox commits inline on the caller's thread — no deferred async
        // write, no cooperative-pool hop).
        #expect(db.validationResultsRowCount() == 2, "both canonical rows committed synchronously")
        #expect(Self.streamRows(db) == 2, "exactly one stream row per canonical row")

        guard let adv, let clean else {
            Issue.record("both outbox writes must return a (resultId, streamId) pair")
            return
        }
        #expect(adv.resultId > 0 && adv.streamId > 0)
        #expect(clean.resultId > 0 && clean.streamId > 0)

        // Each stream event's sourceId equals the canonical rowid it mirrors.
        let events = db.sessionEventStreamStore.pullSince(consumerId: "u9c1-probe", limit: 100)
        let byTable = events.filter { $0.sourceTable == ValidationEventStreamProducer.sourceTable }
        #expect(byTable.count == 2)
        #expect(Set(byTable.map(\.sourceId)) == Set([adv.resultId, clean.resultId]),
                "stream sourceIds must be the exact canonical rowids")

        #expect(Self.producedCount(db, projectRoot: root) == 2, "one produced counter per paired write")

        // Parity audit: canonical count == stream count ⇒ match.
        let audit = ValidationEventStreamProducer.recordParityAudit(db: db, projectRoot: root)
        #expect(audit.diverged == false)
        #expect(audit.canonicalRows == 2 && audit.streamRows == 2)
    }

    // MARK: - Test 3: rollback branch — body throw ⇒ both rolled back, no ghost stream row

    @Test("body throw after the canonical insert rolls back BOTH: no canonical row, no stream row; chain cache not poisoned")
    func bodyThrowRollsBackBoth() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        struct Boom: Error {}
        // Fault seam fires AFTER the canonical INSERT and BEFORE the stream
        // append — proving atomic rollback (canonical-insert-failure ⇒ no
        // stream row is the same rollback guarantee).
        let result = db.validationStore.insertValidationResultWithOutbox(
            sessionId: "sid", filePath: "/tmp/a.swift", validatorName: "swiftc",
            category: "type", exitCode: 1, rawOutput: "err", advisory: "'a' undefined",
            durationMs: 10, projectRoot: nil, outcome: "advisory", reason: nil,
            _afterCanonicalInsert: { _ in throw Boom() }
        )
        #expect(result == nil, "a throw inside the transaction returns nil")
        #expect(db.validationResultsRowCount() == 0, "the canonical row is rolled back — no orphan")
        #expect(Self.streamRows(db) == 0, "no ghost stream row when the body throws")

        // Chain cache not poisoned: a subsequent clean write succeeds and is
        // the only row on both the canonical table and the stream.
        let ok = db.insertValidationResultWithOutbox(
            sessionId: "sid", filePath: "/tmp/b.swift", validatorName: "swiftc",
            category: "type", exitCode: 0, rawOutput: nil, advisory: "",
            durationMs: 5, projectRoot: nil, outcome: "clean", reason: nil
        )
        #expect(ok != nil, "the writer recovers after a rolled-back transaction")
        #expect(db.validationResultsRowCount() == 1)
        #expect(Self.streamRows(db) == 1)
    }

    // MARK: - Test 4: integration — consumer sees produced events, delivers exactly once

    @Test("produced-with-flag-ON events are drained by the real ValidationStreamConsumer via offsets; advisory delivered exactly once")
    func consumerSeesProducedEvents() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }
        let sid = "u9c1-integration"
        let root = "/tmp/senkani-u9c1-int"

        // Produce 2 advisory + 1 clean canonical rows, each with a paired
        // stream row, through the outbox producer (flag ON).
        for (name, ec, outcome) in [("a", Int32(1), "advisory"), ("b", 1, "advisory"), ("c", 0, "clean")] {
            _ = db.insertValidationResultWithOutbox(
                sessionId: sid, filePath: "/tmp/\(name).swift", validatorName: "swiftc",
                category: "type", exitCode: ec, rawOutput: ec == 0 ? nil : "err",
                advisory: ec == 0 ? "" : "'\(name)' undefined", durationMs: 10,
                projectRoot: root, outcome: outcome, reason: nil
            )
        }
        db.flushWrites()
        #expect(db.pendingValidationAdvisories(sessionId: sid).count == 2, "2 advisory rows pending pre-drain")
        #expect(Self.streamRows(db) == 3, "3 canonical rows produced 3 stream rows")

        guard let dispatcher = EventStreamDispatcher.standard(db: db, dualWriteEnabled: { true }) else {
            Issue.record("standard() must build with a live event-stream store")
            return
        }
        let processed = dispatcher.drainToHead(consumerId: EventStreamDispatcher.ConsumerId.validation)
        db.flushWrites()
        #expect(processed == 3, "the consumer advances past all 3 produced events")
        #expect(dispatcher.lag(consumerId: EventStreamDispatcher.ConsumerId.validation) == 0)

        let delivered = db.eventCounts(prefix: ValidationStreamConsumer.deliveredEventType)
            .reduce(0) { $0 + $1.count }
        #expect(delivered == 2, "exactly one auto_validate.delivered per produced advisory event")
        #expect(db.pendingValidationAdvisories(sessionId: sid).isEmpty, "claimed rows are delivered+surfaced")
    }

    // MARK: - Test 5: parity counter DETECTS a deliberate divergence

    @Test("parity audit detects an injected canonical-only row: diverged=true, delta=1, diverge counter emitted")
    func parityDetectsDivergence() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }
        let root = "/tmp/senkani-u9c1-parity"

        // Two paired writes — parity holds.
        for name in ["a", "b"] {
            _ = db.insertValidationResultWithOutbox(
                sessionId: "sid", filePath: "/tmp/\(name).swift", validatorName: "swiftc",
                category: "type", exitCode: 1, rawOutput: "err", advisory: "x",
                durationMs: 10, projectRoot: root, outcome: "advisory", reason: nil
            )
        }
        db.flushWrites()
        let clean = ValidationEventStreamProducer.recordParityAudit(db: db, projectRoot: root)
        #expect(clean.diverged == false, "paired writes report parity")
        #expect(db.eventCounts(projectRoot: root)
            .first(where: { $0.eventType == ValidationEventStreamProducer.parityMatchCounter })?.count == 1)

        // Inject a DELIBERATE divergence: a canonical row with NO paired
        // stream row (the legacy fire-and-forget path).
        db.insertValidationResult(
            sessionId: "sid", filePath: "/tmp/rogue.swift", validatorName: "swiftc",
            category: "type", exitCode: 1, rawOutput: "err", advisory: "rogue",
            durationMs: 10, outcome: "advisory", reason: nil
        )
        db.flushWrites()

        let diverged = ValidationEventStreamProducer.recordParityAudit(db: db, projectRoot: root)
        #expect(diverged.diverged == true, "a canonical-only row is detected as divergence")
        #expect(diverged.delta == 1, "exactly one canonical row lacks a paired stream row")
        #expect(diverged.canonicalRows == 3 && diverged.streamRows == 2)
        #expect(db.eventCounts(projectRoot: root)
            .first(where: { $0.eventType == ValidationEventStreamProducer.parityDivergeCounter })?.count == 1,
            "the diverge counter fires on the detected gap")
    }
}
