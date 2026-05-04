import Testing
import Foundation
@testable import Core

// Regression guard for `bisect-sigtrap-source` (shipped 2026-05-01).
//
// `SessionDatabase.recordEvent(...)` schedules every counter bump as a
// `queue.async { [weak self] in guard let self ... }` block. The
// `guard let self` upgrades to a strong reference for the block's
// duration. When `runMigrations` queues a burst of these (currently 13
// — one per applied migration), the LAST queued block's strong-ref
// release can be the moment the refcount hits zero. ARC fires `deinit`
// synchronously on whichever thread released the final ref — for that
// last block, that's the queue thread itself. Pre-fix the deinit body
// did `queue.sync { sqlite3_close(db) }` from on-queue → Dispatch's
// `__DISPATCH_WAIT_FOR_QUEUE__` precondition tripped → SIGTRAP →
// swiftpm-testing-helper exits with `signal code 5`.
//
// The fix uses `DispatchSpecificKey` to detect the on-queue case and
// close `db` directly without the inner `queue.sync`. This test
// reliably surfaces a regression: revert the reentrancy guard and the
// race lands within a handful of iterations, killing the test process
// with SIGTRAP. The chunked harness's 3-retry policy (see
// `tools/test-safe.sh`) catches the regression even at low per-run
// hit-rate.
@Suite("SessionDatabase — Deinit Reentrancy")
struct SessionDatabaseDeinitTests {

    @Test func deinitFromQueueThreadDoesNotDeadlock() async {
        let iterations = 30
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let path = "/tmp/sdb-deinit-\(i)-\(UUID().uuidString).sqlite"
                    // Allocate + immediately drop the only strong
                    // reference. Init schedules the migration-bump
                    // burst on `queue`; the race window is between
                    // this temporary's release at end-of-statement
                    // and the last queued block's strong-ref release
                    // in its closure body.
                    _ = SessionDatabase(path: path)
                    // Let the queue drain so deinit (and the
                    // underlying sqlite3_close) has run before we
                    // unlink the db files.
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    let fm = FileManager.default
                    try? fm.removeItem(atPath: path)
                    try? fm.removeItem(atPath: path + "-wal")
                    try? fm.removeItem(atPath: path + "-shm")
                }
            }
        }
        // Surviving the loop without SIGTRAP is the assertion.
        #expect(Bool(true))
    }
}
