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
    /// to-back, recording the process's open-fd count before and after
    /// each call. The old per-file Process+Pipe path would push the
    /// count up by ~3 per call (subprocess + pipe pair) until ARC
    /// could catch up; the in-process implementation must not grow
    /// the count beyond a small constant.
    ///
    /// This is the regression-watch test for the EMFILE crash.
    @Test("hashing 200 files does not leak fds (≤ +16 above baseline)")
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

        let baseline = openFDCount()
        for p in paths {
            _ = IndexEngine.gitBlobHash(p)
        }
        let after = openFDCount()

        // Allow a small tolerance for ARC scheduling / SwiftTesting
        // internal allocations; the per-file subprocess path would
        // grow this by at least 200 if not bounded.
        let delta = after - baseline
        #expect(delta <= 16, "fd delta after 200 hashes = \(delta) (baseline=\(baseline), after=\(after))")
    }

    /// Count open file descriptors for the current process by listing
    /// /dev/fd entries. Best-effort — used only to detect order-of-
    /// magnitude leaks (200+), not exact accounting.
    private func openFDCount() -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else {
            return 0
        }
        return entries.count
    }
}
