import Testing
import Foundation
import SQLite3
@testable import Core

/// U.11-pre a-1 — `WorkstreamLifecycle` foundation tests.
///
/// 11 tests covering the three acceptance bullets:
///   - 4 lifecycle transition tests (state machine + validator).
///   - 4 persistence round-trip tests (encode → decode → re-encode
///     byte-identical; v37 table CRUD).
///   - 3 invalid-transition tests (structured error, no crash).
///
/// Sub-items a-2 (PaneSessionDriver actor, App-layer slot,
/// ProjectModel helper) and a-3 (chained `workstream.<event>`
/// row writers + ChainVerifier extension + 100-event chain test)
/// build on this foundation.
@Suite("WorkstreamLifecycle (U.11-pre a-1)")
struct WorkstreamLifecycleTests {

    // MARK: - Helpers

    /// Canonical JSON encoder for byte-identical round-trips. Sorted
    /// keys + ISO-8601 dates so the encode/decode/re-encode pass is
    /// stable across hash-table reorderings.
    private static func canonicalEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    private static func canonicalDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    private static func tempDBPath() -> String {
        let dir = NSTemporaryDirectory() + "senkani-u11-a1-tests/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "lifecycle-\(UUID().uuidString).db"
    }

    private static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;",
            -1, &stmt, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func indexExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type='index' AND name=?;",
            -1, &stmt, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - Transition tests (4)

    @Test("staged → running → paused → running → archived is the canonical happy path")
    func canonicalHappyPath() throws {
        var lc = WorkstreamLifecycle(
            id: UUID(), slug: "happy", state: .staged, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try lc.transition(to: .running)
        #expect(lc.state == .running)
        try lc.transition(to: .paused)
        #expect(lc.state == .paused)
        try lc.transition(to: .running)
        #expect(lc.state == .running)
        try lc.transition(to: .archived)
        #expect(lc.state == .archived)
    }

    @Test("running → blocked → running recovers from a transient block")
    func blockedRecoveryPath() throws {
        var lc = WorkstreamLifecycle(
            id: UUID(), slug: "blocked-recovery", state: .running, createdAt: Date())
        try lc.transition(to: .blocked)
        #expect(lc.state == .blocked)
        try lc.transition(to: .running)
        #expect(lc.state == .running)
    }

    @Test("staged → archived is a valid early-abort")
    func stagedEarlyAbort() throws {
        var lc = WorkstreamLifecycle(
            id: UUID(), slug: "early-abort", state: .staged, createdAt: Date())
        try lc.transition(to: .archived)
        #expect(lc.state == .archived)
    }

    @Test("validateTransition leaves state untouched on rejection")
    func validateDoesNotMutate() {
        var lc = WorkstreamLifecycle(
            id: UUID(), slug: "no-mutate", state: .archived, createdAt: Date())
        #expect(throws: WorkstreamStateTransitionError.self) {
            try lc.transition(to: .running)
        }
        #expect(lc.state == .archived, "rejected transition must not mutate state")
    }

    // MARK: - Persistence / round-trip tests (4)

    @Test("Codable round-trip is byte-identical across three fixtures")
    func codableRoundTripByteIdentical() throws {
        let fixtures: [WorkstreamLifecycle] = [
            WorkstreamLifecycle(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                slug: "fixture-a", state: .staged,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
            WorkstreamLifecycle(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                slug: "fixture-b-with-dashes", state: .running,
                createdAt: Date(timeIntervalSince1970: 1_710_000_000)),
            WorkstreamLifecycle(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                slug: "fixture-c", state: .archived,
                createdAt: Date(timeIntervalSince1970: 1_720_000_000)),
        ]
        let enc = Self.canonicalEncoder()
        let dec = Self.canonicalDecoder()
        for original in fixtures {
            let firstPass = try enc.encode(original)
            let decoded = try dec.decode(WorkstreamLifecycle.self, from: firstPass)
            #expect(decoded == original, "round-trip equality failed for slug=\(original.slug)")
            let secondPass = try enc.encode(decoded)
            #expect(firstPass == secondPass,
                    "second encode must be byte-identical for slug=\(original.slug)")
        }
    }

    @Test("v37 migration creates workstreams table + slug/state indexes")
    func v37CreatesTableAndIndexes() throws {
        let path = Self.tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = SessionDatabase(path: path)
        defer { session.close() }

        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { if let db = db { sqlite3_close(db) } }
        guard let db = db else { return }

        #expect(Self.tableExists(db, "workstreams"))
        #expect(Self.indexExists(db, "idx_workstreams_slug"))
        #expect(Self.indexExists(db, "idx_workstreams_state"))
    }

    @Test("v37 migration ledger advances by exactly one row")
    func v37LedgerAdvancesByOne() throws {
        let path = Self.tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = SessionDatabase(path: path)
        defer { session.close() }

        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { if let db = db { sqlite3_close(db) } }
        guard let db = db else { return }

        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(
            db,
            "SELECT COUNT(*), MAX(description) FROM schema_migrations WHERE version = 37;",
            -1, &stmt, nil
        ) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        let count = Int(sqlite3_column_int(stmt, 0))
        let desc = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        #expect(count == 1, "expected exactly one v37 ledger row, got \(count)")
        #expect(desc.contains("workstreams"),
                "v37 description should reference 'workstreams', got '\(desc)'")
    }

    @Test("workstreams table accepts row + slug UNIQUE enforced")
    func workstreamsAcceptsRowAndSlugUnique() throws {
        let path = Self.tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = SessionDatabase(path: path)
        defer { session.close() }

        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { if let db = db { sqlite3_close(db) } }
        guard let db = db else { return }

        let id1 = UUID()
        let id2 = UUID()

        func insert(_ uuid: UUID, _ slug: String, _ state: String) -> Int32 {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO workstreams (id, slug, state, created_at) VALUES (?, ?, ?, ?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }
            var bytes = withUnsafeBytes(of: uuid.uuid) { Data($0) }
            bytes.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(raw.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            _ = sqlite3_bind_text(stmt, 2, (slug as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = sqlite3_bind_text(stmt, 3, (state as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = sqlite3_bind_int64(stmt, 4, 1_700_000_000)
            return sqlite3_step(stmt)
        }

        #expect(insert(id1, "one", WorkstreamState.staged.rawValue) == SQLITE_DONE)
        // Duplicate slug must fail — UNIQUE INDEX rejects it.
        let dupRC = insert(id2, "one", WorkstreamState.running.rawValue)
        #expect(dupRC == SQLITE_CONSTRAINT, "duplicate slug must trigger SQLITE_CONSTRAINT, got \(dupRC)")
        // Distinct slug for the same state succeeds.
        #expect(insert(id2, "two", WorkstreamState.running.rawValue) == SQLITE_DONE)
    }

    // MARK: - Invalid-transition tests (3)

    @Test("archived → running is rejected with structured error")
    func archivedToRunningRejected() {
        var lc = WorkstreamLifecycle(
            id: UUID(), slug: "archived-locked", state: .archived, createdAt: Date())
        #expect {
            try lc.transition(to: .running)
        } throws: { err in
            guard let tErr = err as? WorkstreamStateTransitionError else { return false }
            return tErr.from == .archived && tErr.to == .running
        }
    }

    @Test("paused → blocked is rejected (only running can move to blocked)")
    func pausedToBlockedRejected() {
        var lc = WorkstreamLifecycle(
            id: UUID(), slug: "paused-no-block", state: .paused, createdAt: Date())
        #expect(throws: WorkstreamStateTransitionError.self) {
            try lc.transition(to: .blocked)
        }
    }

    @Test("staged → blocked is rejected (must move through running first)")
    func stagedToBlockedRejected() {
        var lc = WorkstreamLifecycle(
            id: UUID(), slug: "staged-no-block", state: .staged, createdAt: Date())
        #expect {
            try lc.transition(to: .blocked)
        } throws: { err in
            guard let tErr = err as? WorkstreamStateTransitionError else { return false }
            return tErr.from == .staged
                && tErr.to == .blocked
                && !tErr.reason.isEmpty
        }
    }
}
