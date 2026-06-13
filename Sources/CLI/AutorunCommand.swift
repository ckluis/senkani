import ArgumentParser
import Foundation
import Core

/// `senkani autorun` — the overnight one-task-one-commit loop (U.3, LEG 1).
///
/// Decomposes a free-form markdown task file into U.11
/// `WorkstreamTaskContract` rows, persists them to
/// `~/.senkani/autorun/<run-id>/contracts.json` (the resume seam), and
/// runs each task through a per-task validation gate: every gate command
/// must exit clean for the task to commit; any failure HALTS the loop.
/// Each committed task and each halt emits a notification (Pushover via a
/// fake transport in leg 1 — real-device push is the operator remainder).
///
/// Per `docs/cli-conventions.md` this is a PURE-HOST parent (the
/// `BenchCommand` pattern): it declares NO greedily-binding options of its
/// own that would shadow a future subcommand. Leg-1 options live directly
/// on the single command body:
///
///   --tasks <path>   Markdown task file; one top-level bullet per task.
///   --dry-run        Print the plan and exit; execute nothing.
///
/// LEG-1 SCOPE — deferred to later legs (NOT built here): the TUI /
/// decomposer pane, `--supervise-first`, `ctrl+.` WIP-stash halt,
/// `--allow-classes` + `taskClass` inference, the REAL Pushover transport,
/// and first-run operator approval.
struct Autorun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autorun",
        abstract: "Run a markdown task file as a one-task-one-commit loop with a per-task validation gate."
    )

    @Option(name: .long, help: "Markdown task file; one top-level bullet per task.")
    var tasks: String

    @Flag(name: .long, help: "Print the decomposed plan and per-task gate, then exit without executing anything.")
    var dryRun = false

    func run() throws {
        // Decompose the task file → WorkstreamTaskContract rows.
        let decomposer = TaskDecomposer()
        let contracts: [WorkstreamTaskContract]
        do {
            contracts = try decomposer.decompose(contentsOfFile: tasks)
        } catch TaskDecomposer.DecomposeError.unreadable(let path) {
            FileHandle.standardError.write(
                "senkani autorun: cannot read task file at \(path)\n".data(using: .utf8) ?? Data()
            )
            throw ExitCode.failure
        }

        guard !contracts.isEmpty else {
            FileHandle.standardError.write(
                "senkani autorun: no tasks found in \(tasks) (expected top-level markdown bullets)\n".data(using: .utf8) ?? Data()
            )
            throw ExitCode.failure
        }

        // A stable run id for this invocation. contracts.json is keyed on it.
        let runId = Self.makeRunId()

        // Durably persist the decomposition (the resume seam).
        do {
            try AutorunContractStore.persist(runId: runId, contracts: contracts)
        } catch {
            FileHandle.standardError.write(
                "senkani autorun: failed to persist contracts.json for run \(runId)\n".data(using: .utf8) ?? Data()
            )
            throw ExitCode.failure
        }

        // Wire the real seams: real process launcher + the shared
        // ValidationStore + a PushoverSink over a fake transport (leg 1 —
        // events are observable but no real network; real push is operator).
        let driver = AutorunLoopDriver(
            database: SessionDatabase.shared,
            commandRunner: ProcessCommandRunner(),
            sink: PushoverSink(
                credentials: .synthetic,
                transport: FakePushoverTransport()
            )
        )

        // --dry-run: decompose + persist + print the plan; execute nothing.
        if dryRun {
            driver.dryRun(contracts: contracts)
            return
        }

        // Unattended-refusal precondition: refuse an unattended run when
        // Pushover is not seeded. Leg 1 wires the synthetic (fake-transport)
        // sink, so for the live path we treat that as "not seeded for real"
        // and require an operator on the TTY.
        let attendedOnTTY = isatty(STDIN_FILENO) == 1
        let pushoverSeededForReal = false // leg 1: only the fake transport is wired
        if let refusal = AutorunLoopDriver.unattendedRefusalReason(
            pushoverSeeded: pushoverSeededForReal,
            attendedOnTTY: attendedOnTTY
        ) {
            FileHandle.standardError.write(
                ("senkani autorun: " + refusal + "\n").data(using: .utf8) ?? Data()
            )
            throw ExitCode.failure
        }

        // Live run. Print the plan header, then the loop.
        for line in driver.planLines(for: contracts) { print(line) }
        let result = driver.run(contracts: contracts, runId: runId)
        if !result.allCommitted {
            // The loop halted at a failing task — surface a non-zero exit so
            // scripts/CI see the halt.
            throw ExitCode.failure
        }
    }

    /// A run id for this invocation: a date stamp + a short random suffix so
    /// concurrent invocations don't collide on the contracts.json path.
    static func makeRunId() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let stamp = fmt.string(from: Date())
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "\(stamp)-\(suffix)"
    }
}

/// The REAL `CommandRunner` for the CLI: launches a command line as a
/// subprocess via `/usr/bin/env` (the `senkani exec` precedent), captures
/// combined stdout+stderr, and reports the exit code. Lives in the CLI
/// target (process I/O is wiring, not Core-pure spine logic).
struct ProcessCommandRunner: CommandRunner {
    func run(_ command: String) -> CommandRunResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            // Spawn failure surfaces as a non-zero gate result (the loop
            // halts), carrying the spawn error as output.
            return CommandRunResult(exitCode: 127, output: "spawn failed: \(error)")
        }
        // Read BEFORE waitUntilExit to avoid a pipe-buffer deadlock on large
        // output (the senkani exec precedent).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)
        return CommandRunResult(exitCode: process.terminationStatus, output: output)
    }
}
