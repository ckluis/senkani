import Foundation
import Core
import MLXProseCompiler

// MARK: - ProseSubprocessHandler
//
// `senkani-mcp prose` argv-mode handler. Reads a JSON request from
// stdin, runs the in-process `MLXProseCadenceCompiler`, writes a JSON
// response to stdout, and exits with status 0 (success) or 1 (error).
//
// The CLI side is `Sources/CLI/SubprocessMLXProseCadenceCompiler.swift`
// — see that file for the durable wire contract and the rationale for
// why this hop exists (install-size SLO: linking MLXLMCommon + MLXVLM
// into the `senkani` CLI binary pushed it over the published 50 MB
// budget).
//
// Wire contract — kept symmetric with the CLI side:
//
//   request  (stdin):  {"protocol_version": 1, "prose": "...", "locale": "..."}
//   success  (stdout): {"cron": "..."}                                  exit 0
//   error    (stdout): {"error": {"kind": "...", "detail": "..."}}      exit 1
//
// All error kinds (`unavailable`, `invalidJSON`, `invalidCron`,
// `cancelled`, `unrecognizedPhrase`, `unsupportedLocale`, `version`)
// mirror the discriminator the CLI's `decodeCron(exitCode:stdout:stderr:)`
// recognizes.

enum ProseSubprocessHandler {

    /// Wire-protocol version this build understands. Mismatched
    /// requests get a `"version"` error envelope; the CLI maps that
    /// back to `.unavailable` so the operator sees a clear "no
    /// prose-cadence model available" message instead of a silent
    /// hang.
    static let supportedProtocolVersion: Int = 1

    /// Drive the one-shot stdin/stdout cycle. Never returns — every
    /// path calls `exit(_:)` so the parent process can rely on the
    /// status code as the success-vs-error signal.
    static func run() async -> Never {
        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput

        let raw = stdin.readDataToEndOfFile()
        guard let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            writeError(stdout, kind: "invalidJSON",
                       detail: "request body is not a JSON object")
            exit(1)
        }

        // Version gate before parsing other fields — protects mixed-
        // install scenarios (a v0.4.0 `senkani` against a v0.5.0
        // `senkani-mcp`, say) from silent wire-shape drift.
        if let v = obj["protocol_version"] as? Int, v != supportedProtocolVersion {
            writeError(stdout, kind: "version",
                       detail: "protocol_version \(v) != supported \(supportedProtocolVersion)")
            exit(1)
        }

        guard let prose = obj["prose"] as? String,
              let locale = obj["locale"] as? String else {
            writeError(stdout, kind: "invalidJSON",
                       detail: "request missing required `prose` or `locale` field")
            exit(1)
        }

        let compiler = MLXProseCadenceCompiler()
        do {
            let cadence = try await compiler.compile(prose: prose, locale: locale)
            writeSuccess(stdout, cron: cadence.cron)
            exit(0)
        } catch let e as ProseCadenceCompilerError {
            switch e {
            case .unavailable:
                writeError(stdout, kind: "unavailable", detail: "")
            case .invalidJSON(let d):
                writeError(stdout, kind: "invalidJSON", detail: d)
            case .invalidCron(let d):
                writeError(stdout, kind: "invalidCron", detail: d)
            case .cancelled:
                writeError(stdout, kind: "cancelled", detail: "")
            case .unrecognizedPhrase(let d):
                writeError(stdout, kind: "unrecognizedPhrase", detail: d)
            case .unsupportedLocale(let d):
                writeError(stdout, kind: "unsupportedLocale", detail: d)
            }
            exit(1)
        } catch {
            // Defense-in-depth — the closed taxonomy above should be
            // exhaustive, but a stray non-`ProseCadenceCompilerError`
            // gets mapped to `.unavailable` so the operator gets a
            // recovery path instead of a stack-trace-shaped message.
            writeError(stdout, kind: "unavailable",
                       detail: error.localizedDescription)
            exit(1)
        }
    }

    // MARK: - Stdout writers

    private static func writeSuccess(_ handle: FileHandle, cron: String) {
        let resp: [String: Any] = ["cron": cron]
        if let data = try? JSONSerialization.data(withJSONObject: resp) {
            handle.write(data)
        }
    }

    private static func writeError(
        _ handle: FileHandle,
        kind: String,
        detail: String
    ) {
        let resp: [String: Any] = [
            "error": ["kind": kind, "detail": detail],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: resp) {
            handle.write(data)
        }
    }
}
