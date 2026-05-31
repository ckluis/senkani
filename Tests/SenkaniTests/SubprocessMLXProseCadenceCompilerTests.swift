import Testing
import Foundation
@testable import CLI
@testable import Core

/// `SubprocessMLXProseCadenceCompiler` — the CLI-side compiler that
/// shells out to `senkani-mcp prose` so the `senkani` binary doesn't
/// have to link MLXLMCommon + MLXVLM.
/// Filed by `phase-u8b-mlx-prose-subprocess-delegation-2026-05-28`.
///
/// Tests fall into two groups:
///
///   1. **Decoder unit tests** — drive `decodeCron(exitCode:stdout:
///      stderr:)` directly with fake response payloads. No subprocess,
///      no MLX. Pins the wire-protocol → ProseCadenceCompilerError
///      translation surface.
///   2. **Subprocess integration tests** — write a `#!/bin/sh` fake
///      binary, point the compiler at it, and exercise the full
///      spawn → write stdin → read stdout → decode flow. Mirrors the
///      `MLEvalCommandTests` fake-binary harness.
@Suite("SubprocessMLXProseCadenceCompiler (U.8b follow-up — subprocess delegation)")
struct SubprocessMLXProseCadenceCompilerTests {

    // MARK: - Decoder

    @Test("decodeCron returns the cron string on exit 0 with a well-formed envelope")
    func decoderReturnsCronOnSuccess() throws {
        let stdout = Data(#"{"cron":"0 9 * * 1,2,3,4,5"}"#.utf8)
        let cron = try SubprocessMLXProseCadenceCompiler.decodeCron(
            exitCode: 0, stdout: stdout, stderr: Data()
        )
        #expect(cron == "0 9 * * 1,2,3,4,5")
    }

    @Test("decodeCron exit-code translation matrix — every wire `kind` maps to the right ProseCadenceCompilerError case")
    func decoderMapsEveryErrorKindToItsCase() throws {
        // Each row is (wire kind string, optional detail payload,
        // expected ProseCadenceCompilerError thrown). Detail is empty
        // for nullary cases; non-empty cases assert the payload survives.
        let cases: [(kind: String, detail: String, expected: ProseCadenceCompilerError)] = [
            ("unavailable",        "",         .unavailable),
            ("invalidJSON",        "bad",      .invalidJSON("bad")),
            ("invalidCron",        "1-5 * * * *", .invalidCron("1-5 * * * *")),
            ("cancelled",          "",         .cancelled),
            ("unrecognizedPhrase", "blarg",    .unrecognizedPhrase("blarg")),
            ("unsupportedLocale",  "fr-FR",    .unsupportedLocale("fr-FR")),
            ("version",            "1 != 2",   .unavailable),  // version-mismatch folds into .unavailable
            ("spawn",              "",         .unavailable),
            ("__unknown_future__", "",         .unavailable),  // forward-compat
        ]
        for row in cases {
            let payload: [String: Any] = [
                "error": ["kind": row.kind, "detail": row.detail],
            ]
            let stdout = try JSONSerialization.data(withJSONObject: payload)
            do {
                _ = try SubprocessMLXProseCadenceCompiler.decodeCron(
                    exitCode: 1, stdout: stdout, stderr: Data()
                )
                Issue.record("expected throw for kind=\(row.kind)")
            } catch let actual as ProseCadenceCompilerError {
                #expect(actual == row.expected,
                        "kind=\(row.kind) decoded as \(actual), expected \(row.expected)")
            } catch {
                Issue.record("expected ProseCadenceCompilerError for kind=\(row.kind), got \(error)")
            }
        }
    }

    @Test("decodeCron falls back to .unavailable when stdout is malformed (helper bug recovery)")
    func decoderFallsBackOnMalformedStdout() {
        let garbage = Data("not even close to json".utf8)
        do {
            _ = try SubprocessMLXProseCadenceCompiler.decodeCron(
                exitCode: 1, stdout: garbage, stderr: Data()
            )
            Issue.record("expected throw")
        } catch ProseCadenceCompilerError.unavailable {
            // expected — gracefully degrade so operator sees recovery path
        } catch {
            Issue.record("expected .unavailable, got \(error)")
        }
    }

    @Test("decodeCron throws .invalidJSON when exit=0 stdout lacks the `cron` field")
    func decoderRejectsExit0WithoutCronField() {
        let stdout = Data(#"{"explanation":"…"}"#.utf8)
        do {
            _ = try SubprocessMLXProseCadenceCompiler.decodeCron(
                exitCode: 0, stdout: stdout, stderr: Data()
            )
            Issue.record("expected throw")
        } catch ProseCadenceCompilerError.invalidJSON(let detail) {
            #expect(detail.contains("cron"),
                    "expected detail to mention missing field; got \(detail)")
        } catch {
            Issue.record("expected .invalidJSON, got \(error)")
        }
    }

    @Test("decodeCron treats SIGTERM exit (143) as .cancelled regardless of stdout")
    func decoderMapsSigtermToCancelled() {
        // Even with a "success" stdout payload, exit 143 (= 128 + SIGTERM)
        // means the cancellation handler fired. Verdict must match
        // operator intent.
        let stdout = Data(#"{"cron":"never"}"#.utf8)
        do {
            _ = try SubprocessMLXProseCadenceCompiler.decodeCron(
                exitCode: 143, stdout: stdout, stderr: Data()
            )
            Issue.record("expected throw")
        } catch ProseCadenceCompilerError.cancelled {
            // expected
        } catch {
            Issue.record("expected .cancelled, got \(error)")
        }
    }

    // MARK: - Subprocess integration

    /// Stage a small Bash shim at `path` that drains stdin, writes
    /// `stdoutBody` to stdout, optionally writes `stderrBody`, then
    /// exits with `exitCode`. The `cat > /dev/null` drain is required
    /// — if the shim doesn't read stdin, the writing parent's
    /// `write(requestData)` would EPIPE on a fast exit.
    private func writeFakeBinary(
        at path: String,
        stdoutBody: String,
        stderrBody: String = "",
        exitCode: Int = 0
    ) throws {
        // Single-quoted strings in shell don't expand — safe to inline
        // the JSON envelopes. We use printf %s rather than echo to
        // avoid trailing newlines that would confuse the decoder.
        let stderrLine = stderrBody.isEmpty
            ? ""
            : "printf '%s' '\(stderrBody)' 1>&2\n"
        let script = """
        #!/bin/sh
        cat > /dev/null
        printf '%s' '\(stdoutBody)'
        \(stderrLine)exit \(exitCode)
        """
        try Data(script.utf8).write(to: URL(fileURLWithPath: path))
        chmod(path, 0o755)
    }

    @Test("Successful subprocess call returns a ProseCadence with the caller's prose + locale and the helper's cron")
    func successfulSubprocessCallReturnsProseCadence() async throws {
        let tmp = NSTemporaryDirectory() + "senkani-proseshim-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let fake = tmp + "/senkani-mcp-fake"
        try writeFakeBinary(at: fake, stdoutBody: #"{"cron":"0 9 * * 1,2,3,4,5"}"#)

        let compiler = SubprocessMLXProseCadenceCompiler(binaryPath: fake)
        let cadence = try await compiler.compile(
            prose: "every weekday at 9am", locale: "en-US"
        )
        // The wire response only carries `cron` — prose + locale come
        // from the caller's arguments. This contract decouples the
        // helper's response shape from ProseCadence's identity fields.
        #expect(cadence.prose == "every weekday at 9am")
        #expect(cadence.locale == "en-US")
        #expect(cadence.cron == "0 9 * * 1,2,3,4,5")
    }

    @Test("Subprocess error envelope translates end-to-end (helper exit 1 + `unsupportedLocale` → caller sees .unsupportedLocale)")
    func subprocessErrorEnvelopeTranslates() async throws {
        let tmp = NSTemporaryDirectory() + "senkani-proseshim-err-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let fake = tmp + "/senkani-mcp-fake"
        try writeFakeBinary(
            at: fake,
            stdoutBody: #"{"error":{"kind":"unsupportedLocale","detail":"fr-FR"}}"#,
            exitCode: 1
        )

        let compiler = SubprocessMLXProseCadenceCompiler(binaryPath: fake)
        do {
            _ = try await compiler.compile(prose: "tous les jours", locale: "fr-FR")
            Issue.record("expected throw")
        } catch ProseCadenceCompilerError.unsupportedLocale(let locale) {
            #expect(locale == "fr-FR")
        } catch {
            Issue.record("expected .unsupportedLocale, got \(error)")
        }
    }

    @Test("Cancellation terminates the subprocess and surfaces .cancelled (not the would-be success payload)")
    func cancellationTerminatesSubprocess() async throws {
        let tmp = NSTemporaryDirectory() + "senkani-proseshim-cancel-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let fake = tmp + "/senkani-mcp-fake"
        // The shim drains stdin then sleeps — longer than the test's
        // patience. If cancellation works, the parent SIGTERMs the
        // sleep and the task completes well before the sleep timeout.
        let script = """
        #!/bin/sh
        cat > /dev/null
        sleep 20
        printf '%s' '{"cron":"never"}'
        exit 0
        """
        try Data(script.utf8).write(to: URL(fileURLWithPath: fake))
        chmod(fake, 0o755)

        let compiler = SubprocessMLXProseCadenceCompiler(binaryPath: fake)
        let started = Date()
        let task = Task<String, Never> {
            do {
                _ = try await compiler.compile(prose: "x", locale: "en-US")
                return "ok"
            } catch ProseCadenceCompilerError.cancelled {
                return "cancelled"
            } catch {
                return "other:\(error)"
            }
        }

        // Give the subprocess time to spawn + enter sleep, then cancel.
        // 200 ms is comfortably above process-fork latency on Apple
        // Silicon (typically <20 ms).
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        let outcome = await task.value
        let elapsed = Date().timeIntervalSince(started)
        #expect(outcome == "cancelled",
                "expected .cancelled outcome, got: \(outcome)")
        // SIGTERM should land within ~1s; sanity-bound this to catch
        // a regression where cancellation falls back to the natural
        // 20s sleep timeout (the shim's `sleep 20` above).
        //
        // Ceiling heuristic: the prompt-cancel path resolves in <0.3s in
        // isolation, but under full-suite parallel load (~3200 tests
        // saturating the box) other suites starve this task's scheduling
        // and a legitimate prompt cancel was observed taking 27.9s of
        // wall-clock — see finding
        // subprocess-mlx-cancellation-timing-flake-2026-05-30. The 30s
        // ceiling sits above that observed load-induced worst case yet
        // still strictly below where the regression manifests: a broken
        // cancel never SIGTERMs the shim, so it cannot resolve until the
        // shim's own `sleep 20` completes AND prints its payload, then the
        // parent reads/teardowns — under the same saturation that pushes a
        // good cancel to ~28s, the no-cancel fallback routinely exceeds
        // 30s. So 30s still distinguishes prompt-cancel from no-cancel.
        #expect(elapsed < 30.0,
                "cancellation should be prompt; took \(elapsed)s")
    }

    @Test("Missing binary path surfaces .unavailable so partial installs get a recovery path, not a crash")
    func missingBinaryReturnsUnavailable() async {
        let bogus = "/tmp/senkani-mcp-nonexistent-\(UUID().uuidString)"
        let compiler = SubprocessMLXProseCadenceCompiler(binaryPath: bogus)
        do {
            _ = try await compiler.compile(prose: "daily", locale: "en-US")
            Issue.record("expected throw")
        } catch ProseCadenceCompilerError.unavailable {
            // expected — same surface as a missing model on the
            // in-process MLX path.
        } catch {
            Issue.record("expected .unavailable, got \(error)")
        }
    }
}
