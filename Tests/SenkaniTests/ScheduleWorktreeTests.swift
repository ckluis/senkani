import Testing
import Foundation
@testable import Core

@Suite("ScheduleWorktree") struct ScheduleWorktreeTests {

    // MARK: - Test helpers

    /// Run `/usr/bin/git` with args and return (stdout+stderr, exit).
    private static func git(_ args: [String]) -> (String, Int32) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (error.localizedDescription, -1)
        }
        process.waitUntilExit()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: out, encoding: .utf8) ?? ""
        return (s, process.terminationStatus)
    }

    /// Create a bare-minimum git repo with one commit at `path`.
    private static func seedRepo(at path: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        _ = git(["-C", path, "init", "-q", "-b", "main"])
        _ = git(["-C", path, "config", "user.email", "test@senkani.local"])
        _ = git(["-C", path, "config", "user.name", "senkani-test"])
        try "seed\n".write(
            toFile: path + "/README.md", atomically: true, encoding: .utf8)
        _ = git(["-C", path, "add", "README.md"])
        _ = git(["-C", path, "commit", "-q", "-m", "init"])
    }

    /// Make two tmp dirs (repo, worktree-base), run body, clean up.
    private static func withDirs(_ body: (_ repo: String, _ wtBase: String) throws -> Void) throws {
        let repo = NSTemporaryDirectory() + "senkani-wt-repo-\(UUID().uuidString)"
        let wtBase = NSTemporaryDirectory() + "senkani-wt-base-\(UUID().uuidString)"
        defer {
            // Best-effort cleanup. Use git worktree remove first so the parent
            // repo's registration doesn't dangle after the test.
            _ = git(["-C", repo, "worktree", "prune"])
            try? FileManager.default.removeItem(atPath: repo)
            try? FileManager.default.removeItem(atPath: wtBase)
        }
        try seedRepo(at: repo)
        try FileManager.default.createDirectory(atPath: wtBase, withIntermediateDirectories: true)
        try ScheduleWorktree.withTestDir(wtBase) {
            try body(repo, wtBase)
        }
    }

    // MARK: - 1. Codable backwards-compat: missing `worktree` key decodes as false

    @Test func worktreeDefaultsFalseForPreFieldJSON() throws {
        // JSON written by an older senkani version without the `worktree` key.
        let legacy = """
        {
          "command": "senkani index",
          "createdAt": "2024-01-02T03:04:05Z",
          "cronPattern": "0 2 * * *",
          "enabled": true,
          "name": "legacy-task"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let task = try decoder.decode(ScheduledTask.self, from: legacy)

        #expect(task.name == "legacy-task")
        #expect(task.worktree == false)
    }

    @Test func worktreeFieldRoundtrips() throws {
        let task = ScheduledTask(
            name: "with-worktree",
            cronPattern: "*/30 * * * *",
            command: "senkani bundle",
            worktree: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(task)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(ScheduledTask.self, from: data)

        #expect(loaded.worktree == true)
        #expect(loaded.name == "with-worktree")
    }

    // MARK: - 2. Worktree creation in a git repo

    @Test func createSucceedsInGitRepo() throws {
        try Self.withDirs { repo, wtBase in
            let handle = try ScheduleWorktree.create(
                projectRoot: repo, scheduleName: "nightly")

            #expect(handle.projectRoot == repo)
            #expect(handle.path.hasPrefix(wtBase + "/nightly-"))
            #expect(FileManager.default.fileExists(atPath: handle.path))
            // git must see it as a worktree (detached HEAD of the source repo).
            #expect(ScheduleWorktree.isGitRepo(handle.path))
        }
    }

    // MARK: - 3. Cleanup on success removes the worktree directory

    @Test func cleanupRemovesWorktreeOnSuccess() throws {
        try Self.withDirs { repo, _ in
            let handle = try ScheduleWorktree.create(
                projectRoot: repo, scheduleName: "cleanup-check")
            #expect(FileManager.default.fileExists(atPath: handle.path))

            try ScheduleWorktree.cleanup(handle)

            #expect(!FileManager.default.fileExists(atPath: handle.path))
            // git no longer lists it.
            let (out, _) = Self.git(["-C", repo, "worktree", "list"])
            #expect(!out.contains(handle.path))
        }
    }

    // MARK: - 4. Retain-on-failure: omitting cleanup leaves the dir for inspection

    @Test func worktreeRetainedWhenCleanupSkipped() throws {
        try Self.withDirs { repo, _ in
            let handle = try ScheduleWorktree.create(
                projectRoot: repo, scheduleName: "retain-on-fail")
            // Simulate Schedule.Run hitting a non-zero exit: it skips cleanup().
            // The worktree must still be physically present for the operator to inspect.
            #expect(FileManager.default.fileExists(atPath: handle.path))
            // Also must still be recognized by git as a registered worktree.
            let (out, _) = Self.git(["-C", repo, "worktree", "list"])
            #expect(out.contains(handle.path))
        }
    }

    // MARK: - 5. Non-git-repo rejection

    @Test func createRejectsNonGitRepo() throws {
        let plain = NSTemporaryDirectory() + "senkani-wt-plain-\(UUID().uuidString)"
        let wtBase = NSTemporaryDirectory() + "senkani-wt-base-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: plain)
            try? FileManager.default.removeItem(atPath: wtBase)
        }
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: wtBase, withIntermediateDirectories: true)

        try ScheduleWorktree.withTestDir(wtBase) {
            #expect(throws: ScheduleWorktree.ScheduleWorktreeError.notGitRepo(plain)) {
                _ = try ScheduleWorktree.create(projectRoot: plain, scheduleName: "nope")
            }
        }
    }

    // MARK: - 6. Concurrent creates don't collide

    @Test func concurrentCreatesProduceDistinctWorktrees() async throws {
        // Seed outside the withTestDir block so the lock isn't held across awaits.
        let repo = NSTemporaryDirectory() + "senkani-wt-repo-\(UUID().uuidString)"
        let wtBase = NSTemporaryDirectory() + "senkani-wt-base-\(UUID().uuidString)"
        defer {
            _ = Self.git(["-C", repo, "worktree", "prune"])
            try? FileManager.default.removeItem(atPath: repo)
            try? FileManager.default.removeItem(atPath: wtBase)
        }
        try Self.seedRepo(at: repo)
        try FileManager.default.createDirectory(atPath: wtBase, withIntermediateDirectories: true)

        // Run 4 concurrent creates all targeting the same {repo, schedule-name}.
        // Even in the same wall-clock second, random-suffix must keep paths distinct.
        // Sendable collector — mutation-through-class to satisfy Swift 6 checking.
        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var paths: [String] = []
            private(set) var errors: [Error] = []
            func add(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
            func fail(_ e: Error) { lock.lock(); errors.append(e); lock.unlock() }
        }

        let paths = try ScheduleWorktree.withTestDir(wtBase) { () -> [String] in
            let collector = Collector()
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "t", attributes: .concurrent)

            for _ in 0..<4 {
                group.enter()
                queue.async {
                    defer { group.leave() }
                    do {
                        let h = try ScheduleWorktree.create(
                            projectRoot: repo, scheduleName: "race")
                        collector.add(h.path)
                    } catch {
                        collector.fail(error)
                    }
                }
            }
            group.wait()
            #expect(collector.errors.isEmpty, "unexpected create errors: \(collector.errors)")
            return collector.paths
        }

        #expect(paths.count == 4)
        #expect(Set(paths).count == 4, "paths must be distinct: \(paths)")
        for p in paths {
            #expect(FileManager.default.fileExists(atPath: p))
        }
    }

    // MARK: - 7. Run-id shape sanity

    @Test func runIdShape() {
        let id = ScheduleWorktree.makeRunId()
        // Format: 14-digit UTC timestamp + '-' + 6 lowercase-alnum chars.
        #expect(id.count == 14 + 1 + 6)
        let parts = id.split(separator: "-")
        #expect(parts.count == 2)
        #expect(parts[0].count == 14)
        #expect(parts[0].allSatisfy { $0.isNumber })
        #expect(parts[1].count == 6)
        let alnum = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        #expect(parts[1].unicodeScalars.allSatisfy { alnum.contains($0) })
    }
}
