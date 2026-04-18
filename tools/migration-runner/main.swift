import Foundation
import SQLite3
import Core

// Test-only helper that runs MigrationRunner.run against a given DB path and
// reports its result as a single line of JSON on stdout. Exists solely so
// `MigrationMultiProcTests` can exercise the cross-process flock semantics of
// `MigrationRunner` — the intra-process race is not testable because BSD flock
// is per-process advisory, so same-process callers share one lock holder and
// both proceed (see `sequentialRunnersAreIdempotent` + Bach G2 finding).
//
// Usage:
//   senkani-mig-helper <db-path> [--ready <file>] [--go <file>]
//
// Output (one line on stdout, newline-terminated):
//   {"pid":12345,"applied":[1,2],"target":2,"error":null}
//   {"pid":12345,"applied":[],"target":0,"error":"..."}
//
// Exit codes:
//   0 — migration attempt completed (applied may be empty if another process won)
//   1 — migration threw
//   2 — argument parse / open error

@inline(__always)
private func emit(pid: Int32, applied: [Int], target: Int, error: String?) {
    let appliedList = "[\(applied.map(String.init).joined(separator: ","))]"
    let errPayload: String = {
        guard let e = error else { return "null" }
        let escaped = e
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }()
    let line = "{\"pid\":\(pid),\"applied\":\(appliedList),\"target\":\(target),\"error\":\(errPayload)}\n"
    FileHandle.standardOutput.write(Data(line.utf8))
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: senkani-mig-helper <db-path> [--ready <file>] [--go <file>]\n".utf8))
    exit(2)
}
let dbPath = args[1]

var readyPath: String? = nil
var goPath: String? = nil
var i = 2
while i < args.count {
    switch args[i] {
    case "--ready":
        if i + 1 < args.count { readyPath = args[i + 1]; i += 2; continue }
    case "--go":
        if i + 1 < args.count { goPath = args[i + 1]; i += 2; continue }
    default:
        break
    }
    i += 1
}

// Optional start-barrier: announce readiness, then spin until the driver
// touches the go file. Narrows the window between helper launches so both are
// contending for flock at roughly the same instant.
if let ready = readyPath {
    FileManager.default.createFile(atPath: ready, contents: nil)
}
if let go = goPath {
    while !FileManager.default.fileExists(atPath: go) {
        usleep(5_000) // 5ms
    }
}

var db: OpaquePointer?
let rc = sqlite3_open(dbPath, &db)
guard rc == SQLITE_OK, let dbHandle = db else {
    FileHandle.standardError.write(Data("sqlite3_open rc=\(rc)\n".utf8))
    exit(2)
}
// WAL + busy timeout mirror the production SessionDatabase init path. Without
// busy_timeout, sqlite returns SQLITE_BUSY immediately on a contended lock
// instead of waiting, which would muddy the multi-process test signal.
sqlite3_exec(dbHandle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
sqlite3_busy_timeout(dbHandle, 10_000)

do {
    let report = try MigrationRunner.run(
        db: dbHandle,
        dbPath: dbPath,
        registry: MigrationRegistry.all
    )
    emit(pid: getpid(), applied: report.appliedVersions, target: report.targetVersion, error: nil)
    sqlite3_close(dbHandle)
    exit(0)
} catch {
    emit(pid: getpid(), applied: [], target: 0, error: "\(error)")
    sqlite3_close(dbHandle)
    exit(1)
}
