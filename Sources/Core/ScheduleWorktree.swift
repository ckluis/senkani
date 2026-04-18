import Foundation

/// Creates and cleans up disposable git worktrees for scheduled runs.
///
/// A schedule with `worktree: true` spawns each run inside a fresh
/// `~/.senkani/schedules/worktrees/{name}-{runId}/` tree so concurrent
/// fires and in-flight checkouts can't step on each other. On success
/// the worktree is removed; on failure it's retained for inspection.
public enum ScheduleWorktree {

    public struct Handle: Sendable, Equatable {
        public let path: String
        public let runId: String
        public let projectRoot: String
    }

    public enum ScheduleWorktreeError: Error, LocalizedError, Equatable {
        case notGitRepo(String)
        case createFailed(String)
        case removeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notGitRepo(let p): return "Not a git repository: \(p)"
            case .createFailed(let m): return "Worktree create failed: \(m)"
            case .removeFailed(let m): return "Worktree remove failed: \(m)"
            }
        }
    }

    // MARK: - Test-only override (mirrors ScheduleStore.withTestDirs)

    nonisolated(unsafe) private static var _baseDirOverride: String?
    private static let testLock = NSLock()

    public static var baseDir: String {
        _baseDirOverride ?? FileManager.default.homeDirectoryForCurrentUser.path
            + "/.senkani/schedules/worktrees"
    }

    /// TEST ONLY: redirect `baseDir` to `base` for the duration of `body`.
    /// Holds `testLock` so concurrent callers serialize.
    public static func withTestDir<T>(_ base: String, _ body: () throws -> T) rethrows -> T {
        testLock.lock()
        let prior = _baseDirOverride
        _baseDirOverride = base
        defer {
            _baseDirOverride = prior
            testLock.unlock()
        }
        return try body()
    }

    // MARK: - Public API

    /// True if `path` is inside a git working tree.
    public static func isGitRepo(_ path: String) -> Bool {
        let (_, exit) = runGit(args: ["-C", path, "rev-parse", "--is-inside-work-tree"])
        return exit == 0
    }

    /// Create a detached-HEAD worktree at `baseDir/{name}-{runId}/`.
    /// Fails fast with `.notGitRepo` when `projectRoot` is not a git working tree.
    public static func create(projectRoot: String, scheduleName: String) throws -> Handle {
        guard isGitRepo(projectRoot) else {
            throw ScheduleWorktreeError.notGitRepo(projectRoot)
        }

        let fm = FileManager.default
        let parent = baseDir
        if !fm.fileExists(atPath: parent) {
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }

        let runId = makeRunId()
        let path = parent + "/\(scheduleName)-\(runId)"

        let (stderr, exit) = runGit(args: [
            "-C", projectRoot, "worktree", "add", "--detach", path,
        ])
        guard exit == 0 else {
            throw ScheduleWorktreeError.createFailed(stderr)
        }

        return Handle(path: path, runId: runId, projectRoot: projectRoot)
    }

    /// Remove a worktree via `git worktree remove --force`. On git failure,
    /// best-effort physical delete + `worktree prune` so a stuck registration
    /// can't wedge future runs.
    public static func cleanup(_ handle: Handle) throws {
        let (stderr, exit) = runGit(args: [
            "-C", handle.projectRoot, "worktree", "remove", handle.path, "--force",
        ])
        if exit != 0 {
            try? FileManager.default.removeItem(atPath: handle.path)
            _ = runGit(args: ["-C", handle.projectRoot, "worktree", "prune"])
            throw ScheduleWorktreeError.removeFailed(stderr)
        }
    }

    // MARK: - Internal helpers

    /// Format: `yyyyMMddHHmmss-<6 random alphanum>` in UTC.
    /// Collision probability for two fires in the same second: 1/36^6 ≈ 2×10⁻⁹.
    static func makeRunId() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMddHHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        let ts = fmt.string(from: Date())
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var rand = ""
        for _ in 0..<6 {
            rand.append(alphabet.randomElement()!)
        }
        return "\(ts)-\(rand)"
    }

    private static func runGit(args: [String]) -> (String, Int32) {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (error.localizedDescription, -1)
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (stderr, process.terminationStatus)
    }
}
