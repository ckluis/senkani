import Foundation

/// Single source of truth for spawning `senkani-mig-helper` subprocesses
/// from the test suite.
///
/// ## Why this exists
///
/// The migration-coordination tests (`MigrationMultiProcTests`) need real
/// cross-process flock races, so they spawn a real helper binary. Before
/// 2026-05-15 each test inlined its own `Process` construction, an
/// unbounded "wait for `go` file" spin on the helper side, and a plain
/// `proc.waitUntilExit()` on the parent side with no timeout. When the
/// parent test died for any reason between spawn and `go-file create`,
/// the helper spun forever (busy-poll at 5 ms intervals) and the parent's
/// `defer { removeItem(tmpDir) }` never ran. Across April/May 2026 this
/// pattern leaked ~18 `senkani-mig-helper` zombies that survived multiple
/// `swift test` runs, accumulated ~90 min of CPU each, and contributed
/// to the 2026-05-14 full-suite hang documented at
/// `spec/autonomous/backlog/swift-test-suite-hang-mig-helper-zombies-2026-05-14.md`.
///
/// ## IPC contract (durable, both sides honor)
///
/// 1. Parent constructs a fresh tmp dir `mig-mp-<UUID>/` and a db path
///    inside it.
/// 2. Parent spawns one or two helpers with `<dbPath> --ready <readyA>
///    --go <goFile>` (and optionally a second helper with `--ready
///    <readyB> --go <goFile>` against the same db + go).
/// 3. Helper creates `readyA` (or `readyB`) immediately to signal it
///    has started.
/// 4. Helper spins on `fileExists(goFile)` until parent creates that
///    file, **bounded by `SENKANI_MIG_HELPER_GO_TIMEOUT_SEC`** (default
///    30 s). On timeout the helper writes a `go-fifo timeout` JSON
///    record on stdout and exits 3 — it does **not** outlive its
///    parent.
/// 5. Parent must create `goFile` within the helper's timeout, or
///    accept that the helper will self-exit 3. Either way, parent
///    must reap the helper via `terminateAndWait` (below) — even on
///    test assertion failure, swift-testing cancellation, or thrown
///    error. The pattern is:
///
///    ```swift
///    let pair = try MigrationHelperFixture.spawnPair(dbPath: ..., tmpDir: ...)
///    defer { pair.terminateAndWait(timeout: 60) }
///    try pair.waitReady(timeout: 15)
///    pair.release()                  // creates goFile
///    try pair.joinExitsOrKill(timeout: 60)
///    let resA = try pair.parseStdoutA()
///    let resB = try pair.parseStdoutB()
///    ```
///
/// 6. Parent reaps tmpDir last, after both helpers have exited.
///
/// Anything that spawns `senkani-mig-helper` in `Tests/SenkaniTests/`
/// **must** go through this fixture so the timeout + reap guarantees
/// hold across every test path. Inlining `Process()` again would
/// regress the fix.
enum MigrationHelperFixture {

    /// Parsed helper stdout — one line of JSON per run.
    struct HelperResult: Sendable {
        let pid: Int
        let applied: [Int]
        let target: Int
        let error: String?
    }

    /// Pair of helpers racing a single migration. The fixture
    /// always spawns two; single-helper variants use the same
    /// type with one of the pair unused (rare; not currently
    /// needed).
    final class Pair {
        let dbPath: String
        let tmpDir: String
        let readyA: String
        let readyB: String
        let goFile: String
        let procA: Process
        let procB: Process

        init(
            dbPath: String, tmpDir: String,
            readyA: String, readyB: String, goFile: String,
            procA: Process, procB: Process
        ) {
            self.dbPath = dbPath
            self.tmpDir = tmpDir
            self.readyA = readyA
            self.readyB = readyB
            self.goFile = goFile
            self.procA = procA
            self.procB = procB
        }

        /// Block until both helpers have created their `ready` files,
        /// up to `timeout` seconds. Throws if either helper never signals.
        func waitReady(timeout: TimeInterval) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: readyA),
                   FileManager.default.fileExists(atPath: readyB) {
                    return
                }
                usleep(5_000)
            }
            let aReady = FileManager.default.fileExists(atPath: readyA)
            let bReady = FileManager.default.fileExists(atPath: readyB)
            throw FixtureError.readyTimeout(seconds: timeout, aReady: aReady, bReady: bReady)
        }

        /// Create the `go` file so both helpers can proceed.
        func release() {
            FileManager.default.createFile(atPath: goFile, contents: nil)
        }

        /// Wait up to `timeout` seconds for both helpers to exit. If
        /// either is still alive after the deadline, SIGTERM, brief
        /// grace, then SIGKILL, then `waitUntilExit` (which on a dead
        /// process returns immediately). Returns whether the join was
        /// clean (both exited on their own) or had to force-kill.
        @discardableResult
        func joinExitsOrKill(timeout: TimeInterval) -> JoinOutcome {
            let outcomeA = Self.joinOne(procA, timeout: timeout)
            // Second helper may have been blocked on flock by the first;
            // give it a smaller remaining timeout (it should exit fast
            // once the winner releases the lock). Capped at the same
            // timeout so callers see consistent worst-case bounds.
            let outcomeB = Self.joinOne(procB, timeout: timeout)
            switch (outcomeA, outcomeB) {
            case (.exitedCleanly, .exitedCleanly): return .exitedCleanly
            default: return .forcedKill
            }
        }

        fileprivate static func joinOne(_ proc: Process, timeout: TimeInterval) -> JoinOutcome {
            let deadline = Date().addingTimeInterval(timeout)
            while proc.isRunning && Date() < deadline {
                usleep(20_000) // 20ms — coarse enough not to burn CPU
            }
            if !proc.isRunning {
                proc.waitUntilExit()
                return .exitedCleanly
            }
            // Force-kill path. Send SIGTERM, give 500ms grace, then SIGKILL.
            proc.terminate()
            let graceDeadline = Date().addingTimeInterval(0.5)
            while proc.isRunning && Date() < graceDeadline {
                usleep(20_000)
            }
            if proc.isRunning {
                let pid = proc.processIdentifier
                if pid > 0 { kill(pid, SIGKILL) }
                // Wait briefly for kernel to reap; should be near-instant.
                let killDeadline = Date().addingTimeInterval(1.0)
                while proc.isRunning && Date() < killDeadline {
                    usleep(20_000)
                }
            }
            proc.waitUntilExit() // never blocks once kernel reaped
            return .forcedKill
        }

        /// Reap-on-defer entry point. Idempotent — safe to call multiple
        /// times. Always tears down the tmp dir last.
        func terminateAndWait(timeout: TimeInterval) {
            if procA.isRunning || procB.isRunning {
                _ = joinExitsOrKill(timeout: timeout)
            }
            try? FileManager.default.removeItem(atPath: tmpDir)
        }

        /// Read helper A's stdout to EOF. Safe to call only after
        /// `joinExitsOrKill`.
        func parseStdoutA() throws -> HelperResult {
            return try Self.parseStdout(procA)
        }

        /// Read helper B's stdout to EOF. Safe to call only after
        /// `joinExitsOrKill`.
        func parseStdoutB() throws -> HelperResult {
            return try Self.parseStdout(procB)
        }

        /// Read helper A's stderr to a string.
        func readStderrA() -> String {
            return Self.readAllToString((procA.standardError as! Pipe).fileHandleForReading)
        }

        /// Read helper B's stderr to a string.
        func readStderrB() -> String {
            return Self.readAllToString((procB.standardError as! Pipe).fileHandleForReading)
        }

        private static func parseStdout(_ proc: Process) throws -> HelperResult {
            let stdout = readAllToString((proc.standardOutput as! Pipe).fileHandleForReading)
            let line = stdout
                .split(whereSeparator: { $0.isNewline })
                .last
                .map(String.init) ?? ""
            guard let data = line.data(using: .utf8),
                  let any = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw FixtureError.malformedJSON(line)
            }
            let pid = (any["pid"] as? Int) ?? -1
            let applied = (any["applied"] as? [Int]) ?? []
            let target = (any["target"] as? Int) ?? 0
            let errObj = any["error"]
            let error: String? = (errObj is NSNull) ? nil : (errObj as? String)
            return HelperResult(pid: pid, applied: applied, target: target, error: error)
        }

        private static func readAllToString(_ handle: FileHandle) -> String {
            let data = handle.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    enum JoinOutcome: Equatable, Sendable {
        case exitedCleanly
        case forcedKill
    }

    enum FixtureError: Error, CustomStringConvertible {
        case helperNotFound(searchedFrom: String)
        case readyTimeout(seconds: TimeInterval, aReady: Bool, bReady: Bool)
        case malformedJSON(String)

        var description: String {
            switch self {
            case .helperNotFound(let from):
                return "senkani-mig-helper not found searching from \(from) — run `swift build --product senkani-mig-helper` first"
            case .readyTimeout(let secs, let a, let b):
                return "helper ready barrier timed out after \(secs)s (readyA=\(a) readyB=\(b))"
            case .malformedJSON(let s):
                return "could not parse helper JSON: '\(s)'"
            }
        }
    }

    /// Locate the built helper binary. SwiftPM stamps
    /// `CommandLine.arguments[0]` with a toolchain path (not the test
    /// binary), so we probe well-known locations relative to the current
    /// working directory. `swift test` runs with CWD at the package
    /// root, so `.build/debug/<exe>` is the canonical spot. Callers can
    /// override via `SENKANI_MIG_HELPER`.
    static func helperPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["SENKANI_MIG_HELPER"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            cwd + "/.build/debug/senkani-mig-helper",
            cwd + "/.build/arm64-apple-macosx/debug/senkani-mig-helper",
            cwd + "/.build/x86_64-apple-macosx/debug/senkani-mig-helper",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw FixtureError.helperNotFound(searchedFrom: cwd)
    }

    /// Build a single helper Process. Caller owns the returned Process.
    static func makeHelper(binary: String, dbPath: String, readyPath: String, goPath: String) -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = [dbPath, "--ready", readyPath, "--go", goPath]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        return proc
    }

    /// Spawn a pair of helpers against the same db + go barrier. The
    /// caller passes the db path + tmp dir; the fixture derives the
    /// `ready.A` / `ready.B` / `go` paths and starts both processes.
    ///
    /// On any failure mid-spawn (e.g., `procB.run()` throws), the
    /// caller is expected to attach `terminateAndWait` via `defer`
    /// before invoking this method, OR to wrap this call so any
    /// half-started procA is reaped. Standard pattern:
    ///
    /// ```swift
    /// let pair = try MigrationHelperFixture.spawnPair(dbPath: ..., tmpDir: ...)
    /// defer { pair.terminateAndWait(timeout: 60) }
    /// ```
    ///
    /// Because the `defer` is the *first* line after the throwing
    /// `spawnPair` call, a throw inside `spawnPair` propagates without
    /// leaking a started helper — the throw paths below kill anything
    /// already started before re-throwing.
    static func spawnPair(dbPath: String, tmpDir: String) throws -> Pair {
        let binary = try helperPath()
        let readyA = tmpDir + "ready.A"
        let readyB = tmpDir + "ready.B"
        let goFile = tmpDir + "go"

        let procA = makeHelper(binary: binary, dbPath: dbPath, readyPath: readyA, goPath: goFile)
        let procB = makeHelper(binary: binary, dbPath: dbPath, readyPath: readyB, goPath: goFile)

        do {
            try procA.run()
        } catch {
            throw error
        }
        do {
            try procB.run()
        } catch {
            // procA started, procB failed. Kill procA before re-throwing.
            procA.terminate()
            _ = Pair.joinOne(procA, timeout: 5)
            throw error
        }

        return Pair(
            dbPath: dbPath, tmpDir: tmpDir,
            readyA: readyA, readyB: readyB, goFile: goFile,
            procA: procA, procB: procB
        )
    }
}
