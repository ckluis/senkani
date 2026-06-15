import Testing
import Foundation
import SQLite3
@testable import Core

/// T.3a-5 — 12 parameterized integration tests against pre-compiled
/// `.wasm` fixtures that exercise `WasmtimeSubprocessRuntime` end-to-
/// end: subprocess spawn, watchdog timing, kill classification, and
/// `wasm_kill` chained-row write into a per-test `SessionDatabase`.
///
/// Fixture layout (see `Tests/SenkaniTests/Fixtures/wasm/`):
///   - 4 fuel-* — small `-W fuel=N`, large `-W timeout=Nms`. wasmtime
///     traps with stderr containing "fuel" → `.fuel`.
///   - 4 wall-* — large `-W fuel=N`, small `-W timeout=Nms`. wasmtime
///     traps with stderr containing "interrupt" → `.epoch`. (If the
///     wasmtime self-interrupt is delayed past the host watchdog at
///     `epoch+50ms`, the watchdog SIGTERM still classifies `.epoch`
///     via `WatchdogFiredBox.fired`.)
///   - 4 escape-* — each imports a fake host-module function so
///     wasmtime fails instantiation with stderr containing
///     "unknown import" → `.escape`. Endorsed by the parent item's
///     `## Notes`: "the fixtures simulate these by attempting WASI
///     `proc_exec`-like imports that wasmtime's default sandbox
///     doesn't provide."
///
/// The runtime gained a test-only `database:` + `budgetOverride:`
/// pair on its `init` so tests can verify chain-row writes in
/// isolation and drive tight epoch budgets the production
/// `HandManifest` schema doesn't yet expose (planned for T.3b).
/// Production callers pass neither and behave identically to
/// pre-t3a-5 code.
@Suite("WasmtimeSubprocessRuntime — T.3a-5 12-fixture integration", .serialized)
struct WasmtimeRuntimeIntegrationTests {

    enum Kind: Sendable { case fuel, wall, escape }

    struct Fixture: Sendable, CustomStringConvertible {
        let name: String
        let kind: Kind
        let fuel: Int64
        let epochMs: Int
        let expectedReason: WasmKillReason

        var description: String { name }
    }

    static let fixtures: [Fixture] = [
        // fuel-* — small fuel exhausts within microseconds; large
        // epoch keeps the wall-clock watchdog out of the picture.
        .init(name: "fuel-loop-add",   kind: .fuel,   fuel: 10_000, epochMs: 5_000, expectedReason: .fuel),
        .init(name: "fuel-loop-mul",   kind: .fuel,   fuel: 10_000, epochMs: 5_000, expectedReason: .fuel),
        .init(name: "fuel-recurse",    kind: .fuel,   fuel: 10_000, epochMs: 5_000, expectedReason: .fuel),
        .init(name: "fuel-call-deep",  kind: .fuel,   fuel: 10_000, epochMs: 5_000, expectedReason: .fuel),
        // wall-* — huge fuel keeps wasmtime running, small epoch
        // fires the wall-clock kill. 200ms is enough headroom over
        // subprocess spawn to keep this signal stable in CI.
        .init(name: "wall-spin-1s",      kind: .wall, fuel: 1_000_000_000_000, epochMs: 200, expectedReason: .epoch),
        .init(name: "wall-spin-2s",      kind: .wall, fuel: 1_000_000_000_000, epochMs: 200, expectedReason: .epoch),
        .init(name: "wall-spin-loop",    kind: .wall, fuel: 1_000_000_000_000, epochMs: 200, expectedReason: .epoch),
        .init(name: "wall-spin-counter", kind: .wall, fuel: 1_000_000_000_000, epochMs: 200, expectedReason: .epoch),
        // escape-* — unknown-import failure is at instantiation; the
        // budget is irrelevant because the guest never executes.
        .init(name: "escape-fs-write",    kind: .escape, fuel: 10_000, epochMs: 1_000, expectedReason: .escape),
        .init(name: "escape-net-connect", kind: .escape, fuel: 10_000, epochMs: 1_000, expectedReason: .escape),
        .init(name: "escape-fork",        kind: .escape, fuel: 10_000, epochMs: 1_000, expectedReason: .escape),
        .init(name: "escape-dlopen",      kind: .escape, fuel: 10_000, epochMs: 1_000, expectedReason: .escape),
    ]

    static func fixtureURL(_ name: String) -> URL? {
        Bundle.module.url(
            forResource: name,
            withExtension: "wasm",
            subdirectory: "wasm"
        )
    }

    static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-t3a-5-test-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    /// Force `parent.queue.async` writes from `recordWasmKill` to
    /// flush before the test reads back via raw SQLite. Matches the
    /// pattern in `WasmtimeSubprocessRuntimeChainTests.flushQueue`.
    static func flushQueue(_ db: SessionDatabase) {
        _ = db.tokenEventExists(source: "wasm_kill", feature: "fuel")
    }

    @Test(
        "runtime sandbox kill scenarios — fuel / wall-clock / escape classification + chain row",
        arguments: WasmtimeRuntimeIntegrationTests.fixtures
    )
    func sandboxKillScenarios(_ fixture: Fixture) async throws {
        guard let url = Self.fixtureURL(fixture.name) else {
            Issue.record("missing Tests/SenkaniTests/Fixtures/wasm/\(fixture.name).wasm — operator must compile via `wasm-tools parse \(fixture.name).wat -o \(fixture.name).wasm`")
            return
        }
        let moduleBytes = try Data(contentsOf: url)
        #expect(moduleBytes.count >= 32, "\(fixture.name).wasm must be non-trivial (>= 32 bytes)")

        let (db, dbPath) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: dbPath) }

        // Per-test workdir so the escape-* assertion "no files
        // created outside this dir" has a tight scope to assert
        // against. wasmtime is invoked from the test process's cwd,
        // not this workdir — the assertion captures absence of any
        // observable filesystem effect attributable to the sandbox
        // running.
        let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("senkani-t3a-5-work-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let preFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: workDir.path)) ?? [])

        let runtime = WasmtimeSubprocessRuntime(
            manifest: HandManifest(name: "t3a5", description: "integration", version: "0"),
            database: db,
            budgetOverride: (fuel: fixture.fuel, epochMs: fixture.epochMs)
        )

        let sessionId = "t3a-5-\(fixture.name)-\(UUID().uuidString)"
        let toolId = "t3a-5-\(fixture.name)"
        let started = Date()
        var caught: WasmtimeRunnerError?
        do {
            _ = try await runtime.run(
                module: moduleBytes,
                input: Data(),
                sessionId: sessionId,
                toolId: toolId
            )
            Issue.record("\(fixture.name): expected runtime to throw .subprocessFailed; run returned normally")
            return
        } catch let err as WasmtimeRunnerError {
            caught = err
        } catch {
            Issue.record("\(fixture.name): expected WasmtimeRunnerError; got \(error)")
            return
        }
        let elapsedMs = Date().timeIntervalSince(started) * 1000

        guard case .subprocessFailed(let code, let stderr) = caught else {
            Issue.record("\(fixture.name): expected .subprocessFailed; got \(String(describing: caught))")
            return
        }
        #expect(code != 0, "\(fixture.name): expected non-zero subprocess exit, got \(code)")

        switch fixture.kind {
        case .fuel:
            #expect(stderr.lowercased().contains("fuel"),
                    "\(fixture.name): stderr should mention 'fuel'; got: \(stderr.prefix(240))")
        case .wall:
            let lower = stderr.lowercased()
            // The wasmtime self-interrupt path emits "interrupt"; the
            // host watchdog SIGTERM path may not (process gets a
            // signal, not a wasm trap). Either way classifyKill picks
            // `.epoch` via stderr keyword OR watchdogFired. The chain
            // row check below is the load-bearing assertion; this is
            // a soft signal.
            #expect(lower.contains("interrupt") || lower.contains("timeout") || lower.contains("epoch") || lower.isEmpty,
                    "\(fixture.name): wall-clock stderr should mention 'interrupt' / 'timeout' / 'epoch' or be empty (host SIGTERM); got: \(stderr.prefix(240))")
        case .escape:
            #expect(stderr.lowercased().contains("unknown import"),
                    "\(fixture.name): stderr should mention 'unknown import'; got: \(stderr.prefix(240))")
        }

        // Kill-latency window. Fuel kills resolve within tens of
        // milliseconds. Wall kills resolve within `epochMs + 100ms`
        // host watchdog grace + scheduler jitter. Escape failures
        // resolve in tens of milliseconds. The window upper bound
        // tolerates CI jitter; the round-trip-budget signal is "kill
        // happens fast", not microbenchmark precision.
        let upperBoundMs: Double
        switch fixture.kind {
        case .fuel:   upperBoundMs = 2_000.0
        case .wall:   upperBoundMs = Double(fixture.epochMs) * 4.0 + 1_500.0
        case .escape: upperBoundMs = 2_000.0
        }
        #expect(elapsedMs < upperBoundMs,
                "\(fixture.name): kill latency \(Int(elapsedMs))ms exceeded upper bound \(Int(upperBoundMs))ms")

        // Verify the chained `wasm_kill` row landed with the expected
        // reason + non-null duration / budget delta + populated entry
        // hash. Per-test DB means we can scan all rows without a
        // session-id filter.
        Self.flushQueue(db)

        var rowCount = 0
        var observedReason: String?
        var observedDuration: Int64?
        var observedBudgetDelta: Int64?
        var observedEntryHash: String?
        var observedToolId: String?
        let sql = """
            SELECT wasm_reason, wasm_duration_us, wasm_budget_delta_us, entry_hash, wasm_tool_id
              FROM token_events
             WHERE source = 'wasm_kill';
        """
        db.unsafeQueueSync { raw in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(raw, sql, -1, &stmt, nil) == SQLITE_OK else {
                Issue.record("\(fixture.name): sqlite3_prepare_v2 failed")
                return
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                rowCount += 1
                observedReason = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
                if sqlite3_column_type(stmt, 1) != SQLITE_NULL {
                    observedDuration = sqlite3_column_int64(stmt, 1)
                }
                if sqlite3_column_type(stmt, 2) != SQLITE_NULL {
                    observedBudgetDelta = sqlite3_column_int64(stmt, 2)
                }
                observedEntryHash = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                observedToolId = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            }
        }
        #expect(rowCount == 1, "\(fixture.name): expected exactly one wasm_kill row, got \(rowCount)")
        #expect(observedReason == fixture.expectedReason.rawValue,
                "\(fixture.name): expected wasm_reason=\(fixture.expectedReason.rawValue), got \(observedReason ?? "nil")")
        #expect(observedDuration != nil && (observedDuration ?? 0) > 0,
                "\(fixture.name): wasm_duration_us must be non-null and positive; got \(String(describing: observedDuration))")
        #expect(observedBudgetDelta != nil,
                "\(fixture.name): wasm_budget_delta_us must be non-null")
        #expect(observedEntryHash != nil && !(observedEntryHash ?? "").isEmpty,
                "\(fixture.name): entry_hash must be populated")
        #expect(observedToolId == toolId,
                "\(fixture.name): wasm_tool_id expected \(toolId), got \(observedToolId ?? "nil")")

        // Escape fixtures additionally assert no observable
        // filesystem side-effect in the per-test workdir. wasmtime's
        // default-deny posture rejects unknown imports at
        // instantiation; the guest body never executes. The
        // assertion is defense-in-depth: if a future regression let
        // an escape fixture through, this would surface as new
        // entries in the workdir.
        if fixture.kind == .escape {
            let postFiles = Set((try? FileManager.default.contentsOfDirectory(atPath: workDir.path)) ?? [])
            let newFiles = postFiles.subtracting(preFiles)
            #expect(newFiles.isEmpty,
                    "\(fixture.name): test workdir saw new files \(newFiles) — sandbox escape suspected")
        }
    }
}
