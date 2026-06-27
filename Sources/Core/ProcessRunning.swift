import Foundation

/// V.3 — argv-based, injectable process seam for the real pane-metadata
/// probes (port / branch / PR). Distinct from the shell-string `CommandRunner`
/// (`AutorunLoopDriver`) ON PURPOSE: the probes feed UNTRUSTED strings (a git
/// branch name, a pane working directory) straight into the subprocess
/// arguments, so they MUST go through argv (`Process.arguments`) and NEVER
/// through `/bin/sh -c "<string>"`. Routing branch/dir text through a shell
/// would be a shell-injection vector (a branch literally named `; rm -rf ~`).
/// This seam takes an explicit executable path + an argv array, so the OS
/// passes each argument verbatim with no shell metacharacter interpretation.
///
/// The seam is injectable so the probes are headlessly testable: tests inject
/// a `MockProcessRunner` returning canned stdout/exit per `(executable, args)`
/// without spawning a real subprocess.

/// The captured result of one argv process run: stdout text + the process
/// exit status. stderr is captured-and-discarded by the real runner (the
/// probes never surface it). A spawn failure is reported as exit `127`.
public struct ProcessRunResult: Sendable {
    public let stdout: String
    public let exitCode: Int32

    public init(stdout: String, exitCode: Int32) {
        self.stdout = stdout
        self.exitCode = exitCode
    }
}

/// Injectable argv process seam. `executable` is an absolute path
/// (`/usr/sbin/lsof`, `/usr/bin/git`, …); `args` are passed verbatim as
/// `Process.arguments` — NO shell, NO word-splitting, NO glob expansion.
public protocol ProcessRunning: Sendable {
    func run(executable: String, args: [String]) -> ProcessRunResult
}

/// The REAL runner: launches `executable` with `args` via `Process`,
/// captures stdout through a `Pipe`, routes stderr to its own `Pipe` and
/// DISCARDS it. Reads the stdout pipe BEFORE `waitUntilExit()` to avoid the
/// pipe-buffer deadlock on large output (the `ProcessCommandRunner` /
/// `senkani exec` precedent). On a spawn failure (`process.run()` throws) it
/// returns `ProcessRunResult(stdout: "", exitCode: 127)` — NEVER crashes.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: String, args: [String]) -> ProcessRunResult {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            // Spawn failure (executable missing, not permitted, …). The
            // probes degrade silently, so a spawn failure is just a non-zero
            // exit with no stdout — never a crash.
            return ProcessRunResult(stdout: "", exitCode: 127)
        }
        // Read stdout BEFORE waitUntilExit to avoid a pipe-buffer deadlock on
        // large output (the senkani exec precedent).
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        // Drain stderr too so the writer never blocks on a full pipe, then
        // discard it — the probes don't surface diagnostics.
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        return ProcessRunResult(stdout: stdout, exitCode: process.terminationStatus)
    }
}
