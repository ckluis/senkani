import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Errors raised by `WasmtimeSubprocessRuntime.run`. `wasmtime_missing`
/// is the structured refusal surfaced when `which wasmtime` returns
/// empty — CLI / MCP surfaces translate this into the install-hint
/// string without stringly parsing exception messages. T.3a-1's bench
/// script + `spec/architecture.md` "WASM runtime decision" section use
/// the same install hint (`"brew install wasmtime"`).
public enum WasmtimeRunnerError: Error, Equatable {
    case wasmtime_missing(installHint: String)
    case subprocessFailed(exitCode: Int32, stderr: String)
}

extension WasmtimeRunnerError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .wasmtime_missing(let hint):
            return "wasmtime_missing — \(hint)"
        case .subprocessFailed(let code, let stderr):
            return "wasmtime subprocess failed (exit \(code)): \(stderr)"
        }
    }
}

/// T.3a-2 — one-shot subprocess runtime around the stock `wasmtime`
/// CLI. Each `run(module:input:)` call writes the module bytes to a
/// fresh temp `.wasm` file, spawns `wasmtime run <tempfile>`, pipes
/// `input` to host stdin (which `wasmtime` passes through to the
/// guest's WASI stdin), reads guest stdout to EOF, and cleans up the
/// temp file. No warm pool, no binary length-prefix framing — both
/// were dropped during scope-groom 2026-05-22 because t3a-1's bench
/// showed warm-median 7-8 ms is acceptable for v0.4.0 and the pool
/// benefit is small in absolute terms.
///
/// `init(manifest:)` reads optional fuel / epoch fields off the
/// manifest defensively. Today's `HandSandbox` enum is
/// `none | wasm | proc | full` with no fuel / epoch fields; the
/// helper falls back to `(fuel: 10_000_000, epochMs: 5000)`.
/// T.3b carries the schema bump that promotes these to required.
///
/// **Sibling sub-items.** t3a-3 extends the argv with the wasm-config
/// budget flags `-W fuel=N` and `-W timeout=Nms` and adds a
/// DispatchSource watchdog over the in-flight `Process`. (Flag
/// names: the item's original acceptance specified `--fuel` and
/// `--max-wall-time`, which do not exist as top-level CLI flags in
/// wasmtime 45.0.0 — the semantically-equivalent flags live under
/// the `-W` Wasm-config namespace. See execution evidence for the
/// deviation note + filed follow-up.) t3a-4 wires
/// `recordWasmKill(...)` onto the watchdog path. t3a-5 ships 12
/// parameterized integration tests against fuel-* / wall-* /
/// escape-* .wasm fixtures, all of which use WASI `_start` per the
/// scope-groom decision.
public actor WasmtimeSubprocessRuntime {
    /// Canonical install hint — kept in sync with
    /// `scripts/bench-wasmtime.sh` and the `spec/architecture.md`
    /// "WASM runtime decision" section. CLI / MCP surfaces forward
    /// this string verbatim to operators when the refusal fires.
    public static let installHint = "brew install wasmtime"

    /// Closure that resolves the absolute path to the `wasmtime`
    /// binary. Default implementation runs `/usr/bin/which wasmtime`
    /// and trims the output. Tests inject a closure that throws
    /// `.wasmtime_missing` to exercise the refusal path without
    /// needing a real PATH override.
    public typealias WasmtimeLookup = @Sendable () throws -> URL

    private let manifest: HandManifest
    private let wasmtimeLookup: WasmtimeLookup
    private var cachedExecutableURL: URL?

    public init(
        manifest: HandManifest,
        wasmtimeLookup: WasmtimeLookup? = nil
    ) {
        self.manifest = manifest
        self.wasmtimeLookup = wasmtimeLookup ?? WasmtimeSubprocessRuntime.defaultLookup
    }

    /// Default `wasmtime` lookup: `/usr/bin/which wasmtime`. Throws
    /// `.wasmtime_missing` when `which` exits non-zero or the trimmed
    /// stdout is empty.
    public static let defaultLookup: WasmtimeLookup = {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["wasmtime"]
        let stdoutPipe = Pipe()
        which.standardOutput = stdoutPipe
        which.standardError = Pipe()  // discard
        do {
            try which.run()
        } catch {
            throw WasmtimeRunnerError.wasmtime_missing(installHint: WasmtimeSubprocessRuntime.installHint)
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        which.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard which.terminationStatus == 0, !path.isEmpty else {
            throw WasmtimeRunnerError.wasmtime_missing(installHint: WasmtimeSubprocessRuntime.installHint)
        }
        return URL(fileURLWithPath: path)
    }

    /// Run `module` (a WASI command exporting `_start`) via stock
    /// `wasmtime run <tempfile>`. `input` is delivered to the guest
    /// through host stdin (WASI passthrough); the function returns
    /// whatever the guest wrote to its WASI stdout. Cleans up the
    /// temp file on every exit path.
    ///
    /// Throws `.wasmtime_missing` if `which wasmtime` returns empty,
    /// or `.subprocessFailed` if the spawn fails or the guest exits
    /// non-zero.
    public func run(
        module: Data,
        input: Data,
        sessionId: String? = nil,
        toolId: String? = nil
    ) async throws -> Data {
        let wasmtimeURL = try wasmtimeExecutableURL()
        let tmpURL = try writeTempModule(module)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let (fuel, epochMs) = readBudget(from: manifest)
        let startedAt = Date()

        let process = Process()
        process.executableURL = wasmtimeURL
        process.arguments = [
            "run",
            "-W", "fuel=\(fuel)",
            "-W", "timeout=\(epochMs)ms",
            tmpURL.path,
        ]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw WasmtimeRunnerError.subprocessFailed(
                exitCode: -1, stderr: "spawn failed: \(error)")
        }

        let watchdog = armWatchdog(for: process, epochMs: epochMs)
        defer { watchdog.cancel() }

        stdinPipe.fileHandleForWriting.write(input)
        try? stdinPipe.fileHandleForWriting.close()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            // T.3a-4 — classify the kill + record a chained audit row.
            // Best-effort; the audit-chain write must not throw out of
            // the kill path. Skipped when no sessionId was supplied
            // (today's two t3a-2 tests + future T.3b senkani_exec
            // wiring choose).
            if let sessionId {
                let watchdogFired = watchdog.watchdogFired
                let reason = Self.classifyKill(
                    stderr: stderr,
                    watchdogFired: watchdogFired
                )
                let durationUs = Int64(Date().timeIntervalSince(startedAt) * 1_000_000)
                let budgetDeltaUs = durationUs - Int64(epochMs) * 1_000
                SessionDatabase.shared.recordWasmKill(
                    sessionId: sessionId,
                    reason: reason,
                    durationUs: durationUs,
                    budgetDeltaUs: budgetDeltaUs,
                    toolId: toolId
                )
            }
            throw WasmtimeRunnerError.subprocessFailed(
                exitCode: process.terminationStatus, stderr: stderr)
        }

        return stdoutData
    }

    /// Classify a wasmtime non-zero exit into a `WasmKillReason` for the
    /// `wasm_kill` audit-chain row. Heuristic — reads stderr for
    /// known error strings emitted by wasmtime 45.0.0; the host
    /// watchdog's SIGTERM/SIGKILL force `.epoch` because the watchdog
    /// only arms past the wall-time deadline.
    static func classifyKill(stderr: String, watchdogFired: Bool) -> WasmKillReason {
        if watchdogFired {
            return .epoch
        }
        let lower = stderr.lowercased()
        if lower.contains("fuel") {
            return .fuel
        }
        if lower.contains("interrupt") || lower.contains("timeout") || lower.contains("epoch") {
            return .epoch
        }
        if lower.contains("permission denied")
            || lower.contains("unknown import")
            || lower.contains("not allowed")
            || lower.contains("wasi") && lower.contains("denied")
        {
            return .escape
        }
        return .crash
    }

    /// Read optional `fuel` / `epoch_ms` fields off the manifest if
    /// the active `HandManifest` schema carries them. Today the
    /// `HandSandbox` enum is plain `none | wasm | proc | full` —
    /// neither field exists — so this returns the t3a-3 defaults
    /// `(fuel: 10_000_000, epochMs: 5000)` for every manifest. T.3b
    /// promotes the fields to required and this helper switches to
    /// reading them directly; the runtime API does not change.
    func readBudget(from manifest: HandManifest) -> (fuel: Int64, epochMs: Int) {
        // Defensive Mirror reflection: tolerates future optional
        // `sandboxFuel: Int64?` / `sandboxEpochMs: Int?` fields on
        // `HandManifest` (or a nested struct that replaces the bare
        // `HandSandbox` enum) without a hard schema dep. If the
        // fields are absent or nil, defaults apply.
        var fuel: Int64 = 10_000_000
        var epochMs: Int = 5000

        let mirror = Mirror(reflecting: manifest)
        for child in mirror.children {
            guard let label = child.label else { continue }
            switch label {
            case "sandboxFuel":
                if let unwrapped = unwrapOptional(child.value) as? Int64 {
                    fuel = unwrapped
                } else if let unwrapped = unwrapOptional(child.value) as? Int {
                    fuel = Int64(unwrapped)
                }
            case "sandboxEpochMs":
                if let unwrapped = unwrapOptional(child.value) as? Int {
                    epochMs = unwrapped
                }
            default:
                continue
            }
        }
        return (fuel, epochMs)
    }

    /// Unwraps a `Mirror.Child.value` that may be an `Optional<T>`.
    /// Returns the wrapped value if the optional is `.some`, `nil`
    /// otherwise. Lets `readBudget` accept both `Int64?` and `Int64`
    /// shapes transparently for future schema migrations.
    private func unwrapOptional(_ any: Any) -> Any? {
        let mirror = Mirror(reflecting: any)
        guard mirror.displayStyle == .optional else { return any }
        return mirror.children.first?.value
    }

    /// Arm a `DispatchSourceTimer` at `epochMs + 50` ms that sends
    /// SIGTERM to the in-flight wasmtime subprocess if it's still
    /// alive when the deadline hits. A follow-up 50ms grace timer
    /// escalates to SIGKILL via `kill(pid, SIGKILL)` if SIGTERM
    /// hasn't reaped the process. The caller MUST invoke
    /// `.cancel()` on the returned handle before returning so the
    /// timer source doesn't leak under concurrent `run()` calls —
    /// `WasmtimeSubprocessRuntime.run` does this via `defer`.
    ///
    /// The watchdog is the host-side hard cap. The soft cap is
    /// `-W fuel=N` + `-W timeout=Nms` inside wasmtime itself. Total
    /// kill window is `epoch + 50ms + 50ms = epoch + 100ms` worst
    /// case — well inside the T.3a parent's stated tolerance.
    private nonisolated func armWatchdog(
        for process: Process,
        epochMs: Int
    ) -> WatchdogHandle {
        let queue = DispatchQueue(label: "com.senkani.wasmtime.watchdog", qos: .userInitiated)
        let killTimer = DispatchSource.makeTimerSource(queue: queue)
        let escalateTimer = DispatchSource.makeTimerSource(queue: queue)
        let firedBox = WatchdogFiredBox()

        // Both timers are created suspended. They MUST be resumed at
        // least once before deinit/cancel, or libdispatch crashes
        // with a SIGTRAP precondition fail. We resume both up-front;
        // the escalateTimer is parked at `.distantFuture` until the
        // killTimer's handler reschedules it.
        escalateTimer.schedule(deadline: .distantFuture, repeating: .never)
        escalateTimer.setEventHandler {
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            if pid > 0 {
                _ = kill(pid, SIGKILL)
            }
        }
        escalateTimer.resume()

        killTimer.schedule(
            deadline: .now() + .milliseconds(epochMs + 50),
            repeating: .never
        )
        killTimer.setEventHandler {
            guard process.isRunning else { return }
            firedBox.fired = true
            process.terminate()
            escalateTimer.schedule(
                deadline: .now() + .milliseconds(50),
                repeating: .never
            )
        }
        killTimer.resume()

        return WatchdogHandle(killTimer: killTimer, escalateTimer: escalateTimer, firedBox: firedBox)
    }

    /// Memoized executable lookup. Called from `run`; throws
    /// `.wasmtime_missing` on the first call when the lookup closure
    /// fails. Subsequent calls return the cached URL.
    private func wasmtimeExecutableURL() throws -> URL {
        if let cached = cachedExecutableURL { return cached }
        let url = try wasmtimeLookup()
        cachedExecutableURL = url
        return url
    }

    private func writeTempModule(_ data: Data) throws -> URL {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let tmpURL = tmpDir.appendingPathComponent("wasmtime-runtime-\(UUID().uuidString).wasm")
        try data.write(to: tmpURL)
        return tmpURL
    }
}

/// Owns the pair of `DispatchSourceTimer`s that arm a SIGTERM + SIGKILL
/// escalation against an in-flight wasmtime subprocess. `cancel()` is
/// idempotent and MUST be called by the runtime on every `run()` exit
/// path (happy + failure) to avoid timer-source leaks under concurrent
/// callers. Route B is one-shot — there is no warm pool to share
/// across calls — but defensive cancellation matters when callers
/// fan out many concurrent `run()` invocations.
struct WatchdogHandle {
    let killTimer: any DispatchSourceTimer
    let escalateTimer: any DispatchSourceTimer
    let firedBox: WatchdogFiredBox

    var watchdogFired: Bool { firedBox.fired }

    func cancel() {
        killTimer.cancel()
        escalateTimer.cancel()
    }
}

/// Mutable flag set by the kill timer's event handler when it fires
/// SIGTERM. `run()` reads it after `waitUntilExit()` to classify a
/// host-driven kill as `.epoch` regardless of what wasmtime printed to
/// stderr (the watchdog is the backstop that only arms past the
/// wall-time deadline). Class wrapper because `WatchdogHandle` is a
/// value type and the kill-timer handler needs reference semantics to
/// mutate the flag.
final class WatchdogFiredBox: @unchecked Sendable {
    var fired: Bool = false
}
