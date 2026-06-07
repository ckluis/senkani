import Darwin
import Foundation
import Testing
@testable import Indexer

/// Pairs with `senkani-app-emfile-crash-during-pane-launch-2026-05-15`.
/// The original `IndexEngine.gitBlobHash` spawned `Process` + `Pipe`
/// per file, which exhausted RLIMIT_NOFILE on medium-sized repos and
/// triggered EMFILE on the next system asset load. The rewrite computes
/// the git-blob hash in-process via `Insecure.SHA1`. These tests assert
/// the new shape: deterministic SHA-1 output, no fd burst.
@Suite("IndexEngine hashing — fd-bounded git blob hash")
struct IndexEngineHashingTests {

    /// Reference value computed by `printf 'hello\n' | git hash-object --stdin`:
    /// blob 6\0hello\n → SHA-1 → ce013625030ba8dba906f756967f9e9ca394464a
    private static let helloBlobHash = "ce013625030ba8dba906f756967f9e9ca394464a"

    @Test("gitBlobHash matches git hash-object reference for 'hello\\n'")
    func gitBlobHashMatchesReference() throws {
        let tmp = NSTemporaryDirectory() + "senkani-hash-\(UUID().uuidString).txt"
        try "hello\n".write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let hash = IndexEngine.gitBlobHash(tmp)
        #expect(hash == Self.helloBlobHash)
    }

    @Test("gitBlobHash matches reference for empty file")
    func gitBlobHashEmptyFile() throws {
        // git hash-object on an empty file → e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
        let tmp = NSTemporaryDirectory() + "senkani-hash-empty-\(UUID().uuidString)"
        try "".write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let hash = IndexEngine.gitBlobHash(tmp)
        #expect(hash == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
    }

    @Test("gitBlobHash returns nil for missing file")
    func gitBlobHashMissingFile() {
        let tmp = NSTemporaryDirectory() + "senkani-hash-missing-\(UUID().uuidString)"
        #expect(IndexEngine.gitBlobHash(tmp) == nil)
    }

    @Test("gitBlobHash is deterministic across repeated calls")
    func gitBlobHashDeterministic() throws {
        let tmp = NSTemporaryDirectory() + "senkani-hash-det-\(UUID().uuidString).swift"
        let content = "let answer = 42\n"
        try content.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let h1 = IndexEngine.gitBlobHash(tmp)
        let h2 = IndexEngine.gitBlobHash(tmp)
        #expect(h1 != nil)
        #expect(h1 == h2)
    }

    /// The fd-bounded regression check. Hashes 200 small files back-
    /// to-back, capturing the process's open-fd set before and after
    /// the loop, and asserts that the count of newly-created fds (set
    /// difference) stays well under the per-file-subprocess regression
    /// class. The old per-file `Process` + `Pipe` path would push the
    /// count up by ~3 per call (subprocess + pipe pair) until ARC
    /// could catch up — yielding 200+ fds open at once for a 200-file
    /// batch; the in-process `Insecure.SHA1` implementation must not
    /// grow the count materially.
    ///
    /// This is the regression-watch test for the EMFILE crash.
    ///
    /// **Parallel-mode robustness** (added 2026-05-21 by
    /// `index-engine-hashing-fd-baseline-parallel-flake-2026-05-21`).
    /// The original shape compared raw counts (`/dev/fd` entries
    /// before vs after) with a tight `≤ +16` budget. Under default-
    /// parallel `swift test`, peer test cases concurrently open files
    /// (SessionDatabase sidecars, `TempSessionDatabase` artifacts,
    /// etc.) — process-global `/dev/fd` count is shared, so peers'
    /// open-and-still-held fds at sample time inflate the delta. A
    /// 2026-05-21 run observed `delta=76` (peer noise) vs the ≤16
    /// budget. Two mitigations are applied jointly:
    ///   1. **Set-difference, not count-difference.** Capture the fd
    ///      set at each sample. The post-loop set excludes fds that
    ///      peers opened-and-closed during the loop window — that
    ///      flicker no longer survives. Persistent peer-held fds can
    ///      still appear in the diff, so:
    ///   2. **Relaxed bound (< 100).** The EMFILE-class regression
    ///      (200+ fds open simultaneously) is still detected because
    ///      production leakage + peer noise would clear 200 easily.
    ///      Below 100 catches no micro-leak detail, but the round's
    ///      acceptance for the parallel-flake item explicitly chose
    ///      this trade — the no-subprocess invariant the test guards
    ///      is binary (subprocess path → 200+ open fds, in-process
    ///      path → ~0 from production), not micro-incremental.
    @Test("hashing 200 files does not leak fds (set-diff < 100 above baseline)")
    func hashingDoesNotLeakFDs() throws {
        let tmpDir = NSTemporaryDirectory() + "senkani-fd-leak-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // 200 small files, ~32 bytes each.
        var paths: [String] = []
        for i in 0..<200 {
            let p = tmpDir + "/f-\(i).txt"
            try "content-\(i)-\(String(repeating: "x", count: 16))\n".write(
                toFile: p, atomically: true, encoding: .utf8)
            paths.append(p)
        }

        let before = openFDSet()
        for p in paths {
            _ = IndexEngine.gitBlobHash(p)
        }
        let after = openFDSet()

        // Set-difference excludes fds that peer tests opened AND
        // closed during the loop window — under parallel `swift test`
        // those flickers are common. Persistent peer-held fds inflate
        // the diff modestly; the < 100 bound absorbs that residual
        // while still catching the 200+ per-file-subprocess regression
        // class. See the doc comment above for the full rationale.
        let newFDs = after.subtracting(before)
        let sample = newFDs.sorted().prefix(20).joined(separator: ",")
        #expect(newFDs.count < 100,
                "fd-set delta after 200 hashes = \(newFDs.count) (before=\(before.count), after=\(after.count)). Sample of net new fds: \(sample)")
    }

    /// Snapshot the process's open-fd set as the contents of `/dev/fd`.
    /// Set-valued so callers can compute `after.subtracting(before)`
    /// — peer-test churn that opens-and-closes within the sample
    /// window doesn't survive into the post-snapshot, so it's
    /// excluded from the diff. See the parallel-mode robustness note
    /// on `hashingDoesNotLeakFDs` for why count-difference doesn't
    /// suffice.
    private func openFDSet() -> Set<String> {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else {
            return []
        }
        return Set(entries)
    }
}
