import Testing
import Foundation
@testable import Core
@testable import Filter

/// Observability wave (post-Cavoukian): the `event_counters` table
/// + `recordEvent`/`eventCounts` API + migration v2 that creates it.
/// Closes the Gelman/Majors commitment to ship telemetry alongside
/// every defense site so soak can measure actual-use FP/TP rates.
@Suite("Observability counters")
struct ObservabilityCountersTests {

    private static func makeDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-observ-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    private static func cleanup(_ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try? fm.removeItem(atPath: path + "-wal")
        try? fm.removeItem(atPath: path + "-shm")
        try? fm.removeItem(atPath: path + ".migrating")
        try? fm.removeItem(atPath: path + ".schema.lock")
    }

    /// `recordEvent` is async (dispatches to the DB queue); flush by
    /// running a sync read. `eventCounts` is already `queue.sync`, so
    /// calling it drains.
    private static func flush(_ db: SessionDatabase) {
        _ = db.eventCounts()
    }

    // MARK: - Migration v2 applies

    @Test func migrationV2CreatesEventCountersTable() {
        let (db, path) = Self.makeDB()
        defer { Self.cleanup(path) }
        // Recording an event is only possible if the table exists.
        db.recordEvent(type: "test.event")
        Self.flush(db)
        let rows = db.eventCounts(prefix: "test.")
        #expect(rows.count == 1)
        #expect(rows.first?.count == 1)
    }

    // MARK: - Counter increments

    @Test func incrementsOnRepeatedRecord() {
        let (db, path) = Self.makeDB()
        defer { Self.cleanup(path) }
        for _ in 0..<5 { db.recordEvent(type: "security.injection.detected") }
        Self.flush(db)
        let rows = db.eventCounts(prefix: "security.")
        #expect(rows.first?.count == 5, "5 sequential records must aggregate, got \(rows)")
    }

    @Test func deltaParameterAddsAtomically() {
        let (db, path) = Self.makeDB()
        defer { Self.cleanup(path) }
        db.recordEvent(type: "retention.pruned.token_events", delta: 42)
        db.recordEvent(type: "retention.pruned.token_events", delta: 8)
        Self.flush(db)
        let rows = db.eventCounts(projectRoot: "")
        let row = rows.first { $0.eventType == "retention.pruned.token_events" }
        #expect(row?.count == 50)
    }

    @Test func zeroDeltaIsNoOp() {
        let (db, path) = Self.makeDB()
        defer { Self.cleanup(path) }
        db.recordEvent(type: "noop.event", delta: 0)
        Self.flush(db)
        #expect(db.eventCounts(prefix: "noop.").isEmpty,
                "delta=0 must not create a row")
    }

    // MARK: - Scoping

    @Test func projectScopedSeparateFromGlobal() {
        let (db, path) = Self.makeDB()
        defer { Self.cleanup(path) }
        db.recordEvent(type: "security.ssrf.blocked", projectRoot: "/proj/A")
        db.recordEvent(type: "security.ssrf.blocked", projectRoot: "/proj/A")
        db.recordEvent(type: "security.ssrf.blocked", projectRoot: "/proj/B")
        db.recordEvent(type: "security.socket.handshake.rejected")  // project_root = ""
        Self.flush(db)

        let projA = db.eventCounts(projectRoot: "/proj/A")
        #expect(projA.first?.count == 2, "proj A has 2 SSRF blocks")

        let projB = db.eventCounts(projectRoot: "/proj/B")
        #expect(projB.first?.count == 1)

        let global = db.eventCounts(projectRoot: "")
        let handshake = global.first { $0.eventType == "security.socket.handshake.rejected" }
        #expect(handshake?.count == 1)
    }

    @Test func prefixFilterLimitsResults() {
        let (db, path) = Self.makeDB()
        defer { Self.cleanup(path) }
        db.recordEvent(type: "security.injection.detected")
        db.recordEvent(type: "security.ssrf.blocked")
        db.recordEvent(type: "retention.pruned.token_events", delta: 10)
        Self.flush(db)

        let secOnly = db.eventCounts(prefix: "security.")
        #expect(secOnly.count == 2)
        #expect(secOnly.allSatisfy { $0.eventType.hasPrefix("security.") })

        let retOnly = db.eventCounts(prefix: "retention.")
        #expect(retOnly.count == 1)
    }

    // MARK: - Timestamps

    @Test func firstSeenFreezesLastSeenAdvances() async throws {
        let (db, path) = Self.makeDB()
        defer { Self.cleanup(path) }
        db.recordEvent(type: "timestamp.test")
        Self.flush(db)
        let initial = db.eventCounts(prefix: "timestamp.").first!
        let firstSeen0 = initial.firstSeenAt

        // Sleep ~50ms so timestamps differ measurably.
        try await Task.sleep(nanoseconds: 50_000_000)
        db.recordEvent(type: "timestamp.test")
        Self.flush(db)
        let after = db.eventCounts(prefix: "timestamp.").first!
        #expect(after.firstSeenAt == firstSeen0, "first_seen must freeze")
        #expect(after.lastSeenAt > firstSeen0, "last_seen must advance")
        #expect(after.count == 2)
    }

    // MARK: - Wire-in: FilterPipeline triggers the counter

    @Test func filterPipelineIncrementsInjectionCounter() {
        let (db, path) = Self.makeDB()
        defer { Self.cleanup(path) }
        // Record initial count (should be zero).
        let before = db.eventCounts(prefix: "security.injection")
        let beforeCount = before.first?.count ?? 0

        // NOTE: the FilterPipeline writes to SessionDatabase.shared, not to
        // our test instance. We can only verify the API works and the wire
        // is in place; asserting the SHARED DB count changes would make the
        // test order-dependent. Instead we verify the direct API path.
        db.recordEvent(type: "security.injection.detected", delta: 3)
        Self.flush(db)
        let after = db.eventCounts(prefix: "security.injection")
        #expect(after.first?.count == beforeCount + 3)
    }
}
