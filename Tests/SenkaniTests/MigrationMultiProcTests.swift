import Testing
import Foundation
import SQLite3
@testable import Core

/// Bach G2 — true cross-process migration race.
///
/// `MigrationRunner` uses `flock(2)` to serialize concurrent migrators, but
/// BSD flock is a per-process advisory lock: two `Task.detached` handles in
/// the same test process share one lock holder and both proceed concurrently.
/// The sibling `sequentialRunnersAreIdempotent` test explains that limitation
/// and only verifies the single-process idempotency contract.
///
/// This suite closes the remaining signal gap by spawning a real helper
/// binary (`senkani-mig-helper`, built from `tools/migration-runner/`) twice
/// against the same DB and asserting exactly-once semantics: exactly one
/// process applies the migrations, the other sees them as already applied.
///
/// All helper spawn / barrier / reap mechanics go through
/// `MigrationHelperFixture` — the single source of truth that pins the IPC
/// contract and guarantees no helper outlives its parent test, even on
/// throw, swift-testing cancellation, or assertion failure. Direct
/// `Process()` use of `senkani-mig-helper` is forbidden in test code (the
/// pre-2026-05-15 inline pattern leaked ~18 zombies; see
/// `spec/autonomous/backlog/swift-test-suite-hang-mig-helper-zombies-2026-05-14.md`).
@Suite("MigrationRunner multi-process")
struct MigrationMultiProcTests {

    // MARK: - Tests

    @Test("two concurrent helpers: exactly one applies the registry, the other no-ops")
    func twoHelpersRaceOneWinsOneNoops() throws {
        let tmpDir = NSTemporaryDirectory() + "mig-mp-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir + "race.db"

        let pair = try MigrationHelperFixture.spawnPair(dbPath: dbPath, tmpDir: tmpDir)
        defer { pair.terminateAndWait(timeout: 60) }

        try pair.waitReady(timeout: 15)
        pair.release()
        let outcome = pair.joinExitsOrKill(timeout: 60)
        #expect(outcome == .exitedCleanly,
                "both helpers must exit on their own under the 60s budget; got \(outcome)")

        #expect(pair.procA.terminationStatus == 0, "A exit non-zero; stderr=\(pair.readStderrA())")
        #expect(pair.procB.terminationStatus == 0, "B exit non-zero; stderr=\(pair.readStderrB())")

        let resA = try pair.parseStdoutA()
        let resB = try pair.parseStdoutB()
        #expect(resA.error == nil, "helper A reported error: \(resA.error ?? "")")
        #expect(resB.error == nil, "helper B reported error: \(resB.error ?? "")")

        // Exactly-once: the winner applies MigrationRegistry.all (both v1 and
        // v2 against a pristine DB); the loser blocks on flock, then sees
        // everything applied and reports an empty list. Which one wins is not
        // deterministic — assert the set union and the disjoint partition.
        let expectedAll = MigrationRegistry.all.map(\.version).sorted()
        let union = Set(resA.applied).union(resB.applied)
        #expect(union == Set(expectedAll),
                "union of applied versions must equal the full registry; got A=\(resA.applied) B=\(resB.applied)")
        #expect(resA.applied.isEmpty != resB.applied.isEmpty,
                "exactly one helper must apply, exactly one must no-op; got A=\(resA.applied) B=\(resB.applied)")
        let winner = resA.applied.isEmpty ? resB : resA
        #expect(winner.applied.sorted() == expectedAll,
                "winner must apply every registered migration; got \(winner.applied)")
        #expect(resA.target == resB.target && resA.target == expectedAll.max(),
                "both helpers must report the same target version")

        // Final DB state: schema_migrations row per migration, event_counters
        // table created by v2, user_version stamped to the max.
        var verify: OpaquePointer?
        #expect(sqlite3_open(dbPath, &verify) == SQLITE_OK)
        defer { sqlite3_close(verify) }
        #expect(MigrationRunner.currentVersion(db: verify!) == expectedAll.max())
        #expect(Self.tableExists(verify!, "event_counters"),
                "v2 must have created event_counters")
        #expect(Self.appliedCount(verify!) == expectedAll.count,
                "schema_migrations must have one row per registered migration")

        // flock sidecar must exist but the lockfile (kill-switch) must NOT —
        // the race should have succeeded without either process writing the
        // failure lockfile.
        #expect(FileManager.default.fileExists(atPath: dbPath + ".migrating"),
                "flock sidecar must exist after a successful run")
        #expect(!FileManager.default.fileExists(atPath: dbPath + ".schema.lock"),
                "no helper should have written the kill-switch lockfile")
    }

    @Test("concurrent helpers against an already-migrated DB both no-op")
    func twoHelpersAgainstMigratedDBBothNoop() throws {
        let tmpDir = NSTemporaryDirectory() + "mig-mp-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir + "seeded.db"

        // Pre-apply the full registry so both helpers see a fully-migrated DB.
        var seed: OpaquePointer?
        #expect(sqlite3_open(dbPath, &seed) == SQLITE_OK)
        sqlite3_exec(seed, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_busy_timeout(seed, 5000)
        _ = try MigrationRunner.run(db: seed!, dbPath: dbPath)
        sqlite3_close(seed)

        let pair = try MigrationHelperFixture.spawnPair(dbPath: dbPath, tmpDir: tmpDir)
        defer { pair.terminateAndWait(timeout: 60) }

        try pair.waitReady(timeout: 15)
        pair.release()
        let outcome = pair.joinExitsOrKill(timeout: 60)
        #expect(outcome == .exitedCleanly,
                "both helpers must exit on their own under the 60s budget; got \(outcome)")

        #expect(pair.procA.terminationStatus == 0)
        #expect(pair.procB.terminationStatus == 0)

        let resA = try pair.parseStdoutA()
        let resB = try pair.parseStdoutB()
        #expect(resA.applied.isEmpty && resB.applied.isEmpty,
                "already-migrated DB must yield no-op for both; got A=\(resA.applied) B=\(resB.applied)")
        #expect(resA.error == nil && resB.error == nil)
    }

    @Test("kill-switch lockfile blocks concurrent helper launches")
    func lockfileBlocksBothHelpers() throws {
        let tmpDir = NSTemporaryDirectory() + "mig-mp-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir + "locked.db"

        // Plant the kill-switch lockfile — both helpers must refuse to run.
        try "planted".data(using: .utf8)!.write(to: URL(fileURLWithPath: dbPath + ".schema.lock"))

        let pair = try MigrationHelperFixture.spawnPair(dbPath: dbPath, tmpDir: tmpDir)
        defer { pair.terminateAndWait(timeout: 60) }

        try pair.waitReady(timeout: 15)
        pair.release()
        let outcome = pair.joinExitsOrKill(timeout: 60)
        #expect(outcome == .exitedCleanly,
                "both helpers must exit on their own under the 60s budget; got \(outcome)")

        #expect(pair.procA.terminationStatus == 1, "kill-switch must cause non-zero exit")
        #expect(pair.procB.terminationStatus == 1, "kill-switch must cause non-zero exit")

        let resA = try pair.parseStdoutA()
        let resB = try pair.parseStdoutB()
        #expect(resA.error?.contains("lockfile") == true, "A error must mention lockfile; got: \(resA.error ?? "")")
        #expect(resB.error?.contains("lockfile") == true, "B error must mention lockfile; got: \(resB.error ?? "")")
    }

    @Test("helper exits with status 3 when go barrier never fires (bounded wait)")
    func helperTimesOutWhenGoNeverFires() throws {
        // Prove the helper-side go-barrier timeout (SENKANI_MIG_HELPER_GO_TIMEOUT_SEC):
        // spawn a helper with a `go` path that the parent never creates, and
        // assert the helper exits 3 within the timeout + a small slop margin.
        //
        // This is the keystone test for the 2026-05-15 zombie fix. If the
        // helper's go-barrier ever regresses to unbounded spin, this test
        // hangs the suite (caught here, not in production).

        let tmpDir = NSTemporaryDirectory() + "mig-mp-timeout-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let dbPath = tmpDir + "timeout.db"
        let readyPath = tmpDir + "ready"
        let goPath = tmpDir + "go" // intentionally never created

        let binary = try MigrationHelperFixture.helperPath()
        let proc = MigrationHelperFixture.makeHelper(
            binary: binary, dbPath: dbPath, readyPath: readyPath, goPath: goPath
        )
        // Drive the helper through the short test-only timeout — 1s gives
        // the suite a tight deadline (test completes <3s in the happy
        // path) without flaking when the runner is loaded.
        var env = ProcessInfo.processInfo.environment
        env["SENKANI_MIG_HELPER_GO_TIMEOUT_SEC"] = "1"
        proc.environment = env

        let started = Date()
        try proc.run()
        defer {
            if proc.isRunning {
                proc.terminate()
                let killDeadline = Date().addingTimeInterval(2.0)
                while proc.isRunning && Date() < killDeadline { usleep(20_000) }
                if proc.isRunning, proc.processIdentifier > 0 {
                    kill(proc.processIdentifier, SIGKILL)
                }
                proc.waitUntilExit()
            }
        }

        // Helper must exit within timeout + reasonable slop. Generous
        // upper bound to absorb runner contention.
        let deadline = started.addingTimeInterval(15)
        while proc.isRunning && Date() < deadline {
            usleep(20_000)
        }
        #expect(!proc.isRunning, "helper must exit within 15s when go barrier never fires; was the timeout ignored?")

        proc.waitUntilExit()
        let elapsed = Date().timeIntervalSince(started)

        // The helper should exit fast — well under 10s even on a loaded
        // runner. Asserts the timeout is doing the work, not e.g., the
        // SIGKILL-after-defer fallback.
        #expect(elapsed < 10.0,
                "helper took \(elapsed)s — expected near 1s (timeout). Did the bound work?")

        #expect(proc.terminationStatus == 3,
                "helper must exit with status 3 (go-fifo timeout); got \(proc.terminationStatus) — status 0/1/2 would mean the timeout did not classify correctly")

        // Stdout must contain a parseable error JSON with a timeout marker.
        let stdoutData = (proc.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        #expect(stdout.contains("go-fifo timeout"),
                "stdout must contain go-fifo timeout marker; got: \(stdout)")
    }

    // MARK: - Helpers

    private static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;",
                -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func appliedCount(_ db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM schema_migrations;", -1, &stmt, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int(stmt, 0))
    }
}

