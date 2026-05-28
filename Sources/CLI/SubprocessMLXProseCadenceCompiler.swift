import Foundation
import Core

// MARK: - SubprocessMLXProseCadenceCompiler
//
// U.8b follow-up — subprocess-delegated `ProseCadenceCompiler` that
// keeps MLXLMCommon + MLXVLM OUT of the `senkani` CLI binary.
//
// ### Why subprocess?
//
// Linking MLXLMCommon + MLXVLM directly into CLI pushed the
// `.build/release/senkani` binary from ~14 MB (u8b-3) to ~92 MB
// (u8b-4) — 42 MB over the published `install.size < 50 MB` SLO
// (`spec/slos.md`, measurement captured by `phase-u8b-5-real-model-
// and-ship`'s Execution evidence). `senkani-mcp` already links MLX
// for embed + vision tools, so the cheapest remediation is to hop
// the MLX-fallback call out of the CLI's link graph: the CLI shells
// out to `senkani-mcp prose`, which reads stdin-JSON, runs the
// in-process `MLXProseCadenceCompiler`, and writes stdout-JSON.
//
// The rule arm of `CompositeProseCadenceCompiler` handles common
// cadences ("every weekday at 9am") in sub-ms and never reaches the
// subprocess; only irregular prose ("every other Tuesday at 6pm")
// pays the ~10–50 ms subprocess launch overhead, on top of the
// 0.5–2 s Gemma inference cost — so subprocess overhead is under
// 5% of total `--prose` latency.
//
// ### Wire contract (one-shot per call)
//
//   request  (stdin):  {"protocol_version": 1, "prose": "...", "locale": "..."}
//   success  (stdout): {"cron": "..."}                                  exit 0
//   error    (stdout): {"error": {"kind": "...", "detail": "..."}}      exit non-zero
//
// Error `kind` strings (string discriminator) map to
// `ProseCadenceCompilerError` cases:
//
//   "unavailable" / "version" / "spawn"  → .unavailable
//   "invalidJSON"                        → .invalidJSON(detail)
//   "invalidCron"                        → .invalidCron(detail)
//   "cancelled"                          → .cancelled
//   "unrecognizedPhrase"                 → .unrecognizedPhrase(detail)
//   "unsupportedLocale"                  → .unsupportedLocale(detail)
//
// If `senkani-mcp` can't be located, OR the subprocess exits 0 with
// a malformed stdout, the compiler throws `.unavailable` so the
// operator sees a clear "no prose-cadence model is available; pass
// --cron instead" recovery path — same surface a missing model
// would produce on the in-process path. This keeps partial installs
// graceful.
//
// ### Cancellation
//
// `compile()` is wrapped in `withTaskCancellationHandler { … }
// onCancel: { process.terminate() }`. When the caller's Task is
// cancelled, the subprocess receives SIGTERM, `readDataToEndOfFile`
// unblocks via pipe-close, and the post-wait `Task.isCancelled`
// check throws `.cancelled` to the caller. Critical because a
// cold-load of Gemma can take 5–15 s on first call.

public struct SubprocessMLXProseCadenceCompiler: ProseCadenceCompiler {

    /// Wire-protocol version pinned in every request envelope. The
    /// `senkani-mcp prose` handler rejects requests carrying a
    /// different value with `{"error":{"kind":"version", ...}}`
    /// which maps back to `.unavailable`. Bump together when the
    /// wire shape changes.
    static let protocolVersion: Int = 1

    /// Override for tests; production callers pass `nil` so the
    /// compiler resolves the helper via `MLEval.discoverMCPBinary()`
    /// at every `compile()` call (re-resolving avoids stale absolute
    /// paths across `swift build` cycles in dev).
    public let binaryPath: String?

    public init(binaryPath: String? = nil) {
        self.binaryPath = binaryPath
    }

    public func compile(prose: String, locale: String) async throws -> ProseCadence {
        // Earliest cheap rejection — mirrors MLXProseCadenceCompiler's
        // cancel-first ordering. A cancelled call never spawns a
        // subprocess.
        try Task.checkCancellation()

        // Locate the helper. `.unavailable` is the silent-fallback
        // signal so a partial install (CLI but no senkani-mcp) still
        // surfaces an actionable message instead of a crash.
        let binary: String
        if let override = binaryPath {
            binary = override
        } else if let discovered = MLEval.discoverMCPBinary() {
            binary = discovered
        } else {
            throw ProseCadenceCompilerError.unavailable
        }

        // Build the request envelope. JSONSerialization handles the
        // string escaping for free.
        let request: [String: Any] = [
            "protocol_version": Self.protocolVersion,
            "prose": prose,
            "locale": locale,
        ]
        let requestData: Data
        do {
            requestData = try JSONSerialization.data(withJSONObject: request)
        } catch {
            // Should never happen — `prose` and `locale` are Strings —
            // but stay paranoid in case a future caller passes a
            // pathological encoding.
            throw ProseCadenceCompilerError.invalidJSON(
                "request encode failed: \(error.localizedDescription)"
            )
        }

        // Process is non-Sendable in Swift 6's strict-concurrency model.
        // The `onCancel:` closure is `@Sendable`, so we box the
        // Process behind an `@unchecked Sendable` reference whose only
        // shared mutation is the thread-safe `terminate()` call.
        final class ProcessBox: @unchecked Sendable {
            let process = Process()
        }
        let box = ProcessBox()
        let process = box.process

        let cron: String = try await withTaskCancellationHandler {
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["prose"]

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                // Spawn failed (helper missing exec bit, sandbox refused,
                // …). Same recovery surface as discovery failure.
                throw ProseCadenceCompilerError.unavailable
            }

            // Write the request, close stdin so the helper sees EOF and
            // can start work. `write` is forgiving here — if the
            // subprocess closed its read end (rare but possible on a
            // crashed helper), we still drain stdout and let the
            // decoder surface the verdict.
            stdinPipe.fileHandleForWriting.write(requestData)
            try? stdinPipe.fileHandleForWriting.close()

            // Read until EOF. Cancellation terminates the subprocess
            // which closes both pipes kernel-side and unblocks these
            // calls — that's why the cancellation handler can be a
            // simple `terminate()` without coordinating directly with
            // the readers.
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            // Post-wait cancellation check — covers the race where the
            // cancellation handler fired AFTER the subprocess finished
            // cleanly. `Task.isCancelled` is a synchronous read; no
            // throw, so we explicitly throw `.cancelled` instead of
            // mis-decoding the (now-irrelevant) success output.
            if Task.isCancelled {
                throw ProseCadenceCompilerError.cancelled
            }

            return try Self.decodeCron(
                exitCode: process.terminationStatus,
                stdout: outData,
                stderr: errData
            )
        } onCancel: {
            // SIGTERM. Subprocess receives the signal, closes pipes,
            // body unblocks. `terminate()` is documented thread-safe.
            box.process.terminate()
        }

        return ProseCadence(prose: prose, locale: locale, cron: cron)
    }

    // MARK: - Wire decoder
    //
    // `static` + `internal` so unit tests can exercise the parse
    // surface mock-driven (no subprocess, no MLX). Mirrors
    // `MLXProseCadenceCompiler.parseAndValidate(raw:)`'s test-seam
    // pattern.

    /// Decode the senkani-mcp prose response envelope into the cron
    /// string, or throw the case implied by exit code + error kind.
    static func decodeCron(
        exitCode: Int32,
        stdout: Data,
        stderr _: Data
    ) throws -> String {
        // SIGTERM exit (128 + SIGTERM(15) = 143) means the subprocess
        // was killed externally OR our cancellation handler fired.
        // Either way, the operator's intent is "this call shouldn't
        // be processed" — map to `.cancelled` so the verdict matches.
        if exitCode == 143 {
            throw ProseCadenceCompilerError.cancelled
        }

        // Stdout MUST be a JSON object on every path (success + error).
        // Anything else (empty, garbage, partial write) is a helper
        // bug; surface `.unavailable` so the operator gets a clear
        // recovery path. Stderr is unused for parse — the helper's
        // `senkani.prose: Gemma VLM loaded` log line writes there and
        // is operationally irrelevant to the call's success.
        guard !stdout.isEmpty,
              let decoded = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
            throw ProseCadenceCompilerError.unavailable
        }

        if exitCode == 0 {
            guard let cron = decoded["cron"] as? String else {
                throw ProseCadenceCompilerError.invalidJSON(
                    "response missing `cron` field"
                )
            }
            return cron
        }

        // Non-zero exit MUST carry an `error` object (the helper's
        // contract). A non-zero exit with no error envelope is a
        // helper bug → `.unavailable`.
        guard let errObj = decoded["error"] as? [String: Any],
              let kind = errObj["kind"] as? String else {
            throw ProseCadenceCompilerError.unavailable
        }
        let detail = (errObj["detail"] as? String) ?? ""
        switch kind {
        case "unavailable", "version", "spawn":
            throw ProseCadenceCompilerError.unavailable
        case "invalidJSON":
            throw ProseCadenceCompilerError.invalidJSON(detail)
        case "invalidCron":
            throw ProseCadenceCompilerError.invalidCron(detail)
        case "cancelled":
            throw ProseCadenceCompilerError.cancelled
        case "unrecognizedPhrase":
            throw ProseCadenceCompilerError.unrecognizedPhrase(detail)
        case "unsupportedLocale":
            throw ProseCadenceCompilerError.unsupportedLocale(detail)
        default:
            // Unknown kind — future helper version, malformed payload,
            // or wire-protocol drift. Recover via .unavailable.
            throw ProseCadenceCompilerError.unavailable
        }
    }
}
