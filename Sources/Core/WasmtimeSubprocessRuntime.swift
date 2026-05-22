import Foundation

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
/// `init(manifest:)` reads no manifest fields in this round — today's
/// `HandSandbox` enum is `none | wasm | proc | full` with no fuel /
/// epoch fields. The parameter is plumbed so t3a-3 can layer a
/// `readBudget(from:)` helper without an API break.
///
/// **Sibling sub-items.** t3a-3 extends the argv with `--fuel <N>
/// --max-wall-time <Nms>` flags and adds a DispatchSource watchdog
/// over the in-flight `Process`. t3a-4 wires `recordWasmKill(...)`
/// onto the watchdog path. t3a-5 ships 12 parameterized integration
/// tests against fuel-* / wall-* / escape-* .wasm fixtures, all of
/// which use WASI `_start` per the scope-groom decision.
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
    public func run(module: Data, input: Data) async throws -> Data {
        let wasmtimeURL = try wasmtimeExecutableURL()
        let tmpURL = try writeTempModule(module)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let process = Process()
        process.executableURL = wasmtimeURL
        process.arguments = ["run", tmpURL.path]

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

        stdinPipe.fileHandleForWriting.write(input)
        try? stdinPipe.fileHandleForWriting.close()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            throw WasmtimeRunnerError.subprocessFailed(
                exitCode: process.terminationStatus, stderr: stderr)
        }

        return stdoutData
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
