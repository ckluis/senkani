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
@Suite("MigrationRunner multi-process")
struct MigrationMultiProcTests {

    /// Parsed helper stdout — one line of JSON per run.
    private struct HelperResult {
        let pid: Int
        let applied: [Int]
        let target: Int
        let error: String?
    }

    /// Locate the built helper binary. SwiftPM stamps `CommandLine.arguments[0]`
    /// with a toolchain path (not the test binary), so we probe well-known
    /// locations relative to the current working directory instead. `swift
    /// test` runs with CWD at the package root, so `.build/debug/<exe>` is
    /// the canonical spot. Callers can override via `SENKANI_MIG_HELPER`.
    private static func helperPath() throws -> String {
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
        throw HelperMissing.notFound(searchedFrom: cwd)
    }

    private enum HelperMissing: Error, CustomStringConvertible {
        case notFound(searchedFrom: String)
        var description: String {
            switch self {
            case .notFound(let from):
                return "senkani-mig-helper not found searching from \(from) — run `swift build --product senkani-mig-helper` first"
            }
        }
    }

    /// Spawn a helper process, return its stdout/stderr/exit status.
    private static func runHelper(
        binary: String,
        dbPath: String,
        readyPath: String,
        goPath: String
    ) -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = [dbPath, "--ready", readyPath, "--go", goPath]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        return proc
    }

    private static func parse(_ stdout: String) throws -> HelperResult {
        // Helper prints exactly one JSON line, followed by a trailing newline.
        let line = stdout
            .split(whereSeparator: { $0.isNewline })
            .last
            .map(String.init) ?? ""
        guard let data = line.data(using: .utf8),
              let any = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw HelperParse.malformed(line)
        }
        let pid = (any["pid"] as? Int) ?? -1
        let applied = (any["applied"] as? [Int]) ?? []
        let target = (any["target"] as? Int) ?? 0
        let errObj = any["error"]
        let error: String? = (errObj is NSNull) ? nil : (errObj as? String)
        return HelperResult(pid: pid, applied: applied, target: target, error: error)
    }

    private enum HelperParse: Error, CustomStringConvertible {
        case malformed(String)
        var description: String {
            switch self {
            case .malformed(let s): return "could not parse helper JSON: '\(s)'"
            }
        }
    }

    private static func readAllToString(_ handle: FileHandle) -> String {
        let data = handle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Tests

    @Test("two concurrent helpers: exactly one applies the registry, the other no-ops")
    func twoHelpersRaceOneWinsOneNoops() throws {
        let binary = try Self.helperPath()

        let tmpDir = NSTemporaryDirectory() + "mig-mp-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let dbPath = tmpDir + "race.db"
        let readyA = tmpDir + "ready.A"
        let readyB = tmpDir + "ready.B"
        let goFile = tmpDir + "go"

        let procA = Self.runHelper(binary: binary, dbPath: dbPath, readyPath: readyA, goPath: goFile)
        let procB = Self.runHelper(binary: binary, dbPath: dbPath, readyPath: readyB, goPath: goFile)

        try procA.run()
        try procB.run()

        // Spin until both helpers signal readiness, then release the barrier
        // so both race for flock within the same few microseconds.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: readyA),
               FileManager.default.fileExists(atPath: readyB) {
                break
            }
            usleep(5_000)
        }
        #expect(FileManager.default.fileExists(atPath: readyA), "helper A never signaled ready")
        #expect(FileManager.default.fileExists(atPath: readyB), "helper B never signaled ready")

        FileManager.default.createFile(atPath: goFile, contents: nil)

        procA.waitUntilExit()
        procB.waitUntilExit()

        let outA = Self.readAllToString((procA.standardOutput as! Pipe).fileHandleForReading)
        let errA = Self.readAllToString((procA.standardError as! Pipe).fileHandleForReading)
        let outB = Self.readAllToString((procB.standardOutput as! Pipe).fileHandleForReading)
        let errB = Self.readAllToString((procB.standardError as! Pipe).fileHandleForReading)

        #expect(procA.terminationStatus == 0, "A exit status non-zero; stderr=\(errA)")
        #expect(procB.terminationStatus == 0, "B exit status non-zero; stderr=\(errB)")

        let resA = try Self.parse(outA)
        let resB = try Self.parse(outB)

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
        let binary = try Self.helperPath()

        let tmpDir = NSTemporaryDirectory() + "mig-mp-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let dbPath = tmpDir + "seeded.db"

        // Pre-apply the full registry so both helpers see a fully-migrated DB.
        var seed: OpaquePointer?
        #expect(sqlite3_open(dbPath, &seed) == SQLITE_OK)
        sqlite3_exec(seed, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_busy_timeout(seed, 5000)
        _ = try MigrationRunner.run(db: seed!, dbPath: dbPath)
        sqlite3_close(seed)

        let readyA = tmpDir + "ready.A"
        let readyB = tmpDir + "ready.B"
        let goFile = tmpDir + "go"

        let procA = Self.runHelper(binary: binary, dbPath: dbPath, readyPath: readyA, goPath: goFile)
        let procB = Self.runHelper(binary: binary, dbPath: dbPath, readyPath: readyB, goPath: goFile)

        try procA.run()
        try procB.run()

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: readyA),
               FileManager.default.fileExists(atPath: readyB) {
                break
            }
            usleep(5_000)
        }
        FileManager.default.createFile(atPath: goFile, contents: nil)

        procA.waitUntilExit()
        procB.waitUntilExit()

        let outA = Self.readAllToString((procA.standardOutput as! Pipe).fileHandleForReading)
        let outB = Self.readAllToString((procB.standardOutput as! Pipe).fileHandleForReading)

        let resA = try Self.parse(outA)
        let resB = try Self.parse(outB)

        #expect(procA.terminationStatus == 0)
        #expect(procB.terminationStatus == 0)
        #expect(resA.applied.isEmpty && resB.applied.isEmpty,
                "already-migrated DB must yield no-op for both; got A=\(resA.applied) B=\(resB.applied)")
        #expect(resA.error == nil && resB.error == nil)
    }

    @Test("kill-switch lockfile blocks concurrent helper launches")
    func lockfileBlocksBothHelpers() throws {
        let binary = try Self.helperPath()

        let tmpDir = NSTemporaryDirectory() + "mig-mp-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let dbPath = tmpDir + "locked.db"

        // Plant the kill-switch lockfile — both helpers must refuse to run.
        try "planted".data(using: .utf8)!.write(to: URL(fileURLWithPath: dbPath + ".schema.lock"))

        let readyA = tmpDir + "ready.A"
        let readyB = tmpDir + "ready.B"
        let goFile = tmpDir + "go"

        let procA = Self.runHelper(binary: binary, dbPath: dbPath, readyPath: readyA, goPath: goFile)
        let procB = Self.runHelper(binary: binary, dbPath: dbPath, readyPath: readyB, goPath: goFile)

        try procA.run()
        try procB.run()

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: readyA),
               FileManager.default.fileExists(atPath: readyB) {
                break
            }
            usleep(5_000)
        }
        FileManager.default.createFile(atPath: goFile, contents: nil)

        procA.waitUntilExit()
        procB.waitUntilExit()

        #expect(procA.terminationStatus == 1, "kill-switch must cause non-zero exit")
        #expect(procB.terminationStatus == 1, "kill-switch must cause non-zero exit")

        let outA = Self.readAllToString((procA.standardOutput as! Pipe).fileHandleForReading)
        let outB = Self.readAllToString((procB.standardOutput as! Pipe).fileHandleForReading)
        let resA = try Self.parse(outA)
        let resB = try Self.parse(outB)
        #expect(resA.error?.contains("lockfile") == true, "A error must mention lockfile; got: \(resA.error ?? "")")
        #expect(resB.error?.contains("lockfile") == true, "B error must mention lockfile; got: \(resB.error ?? "")")
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
