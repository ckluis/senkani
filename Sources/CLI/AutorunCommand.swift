import ArgumentParser
import Foundation
import Core

/// `senkani autorun` — the overnight one-task-one-commit loop (U.3, legs 1–2).
///
/// Decomposes a free-form markdown task file into U.11
/// `WorkstreamTaskContract` rows, persists them to
/// `~/.senkani/autorun/<run-id>/contracts.json` (the resume seam), and
/// runs each task through a per-task validation gate: every gate command
/// must exit clean for the task to commit; any failure HALTS the loop.
/// Each committed task and each halt emits a notification through a
/// seed-gated PushoverSink (leg 4): the real KeychainPushoverTransport when
/// the operator has seeded the Pushover credential, otherwise inert. The
/// live-device push proof remains the operator remainder.
///
/// Per `docs/cli-conventions.md` this is a PURE-HOST parent (the
/// `BenchCommand` pattern): it declares NO greedily-binding options of its
/// own that would shadow a future subcommand. Leg-1 options live directly
/// on the single command body:
///
///   --tasks <path>        Markdown task file; one top-level bullet per task.
///   --dry-run             Print the plan and exit; execute nothing.
///   --supervise-first N   Pause for operator y/n after the gate clears on the
///                         first N tasks (leg 2); n aborts. 0 = unattended.
///   --allow-classes CSV   Restrict unattended autorun to tasks whose inferred
///                         class is on the comma-list (leg 3); out-of-list tasks
///                         pause for operator y/n regardless of --supervise-first.
///
/// DEFERRED to later legs (NOT built here): the TUI / decomposer pane and
/// first-run operator approval. (`ctrl+.` WIP-stash halt is disqualified —
/// the loop never mutates the working tree, so there is no in-flight diff to
/// stash.) Leg 4 wired the real seed-gated Pushover transport; proving live
/// device delivery against api.pushover.net is the operator leg C walk.
struct Autorun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autorun",
        abstract: "Run a markdown task file as a one-task-one-commit loop with a per-task validation gate."
    )

    @Option(name: .long, help: "Markdown task file; one top-level bullet per task.")
    var tasks: String

    @Flag(name: .long, help: "Print the decomposed plan and per-task gate, then exit without executing anything.")
    var dryRun = false

    @Option(name: .long, help: "Pause for operator y/n after the gate clears on the first N tasks; n aborts the run. 0 = fully unattended.")
    var superviseFirst: Int = 0

    @Option(name: .long, help: "Restrict unattended autorun to tasks whose inferred class is in this comma-list (e.g. test-fix,docs). Out-of-list tasks pause for operator y/n regardless of --supervise-first; an out-of-list task in an unattended (no-TTY) run aborts via the fail-safe stdin reader.")
    var allowClasses: String?

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
        // ValidationStore + a seed-gated PushoverSink (leg 4). The selector
        // probes the vault (value-free, fail-closed) and installs the REAL
        // KeychainPushoverTransport when the operator has seeded the
        // Pushover credential; otherwise the sink is inert. `seededForReal`
        // drives the unattended-refusal gate below, derived from the SAME
        // probe so the two can never disagree. (Live device push remains the
        // operator leg C of phase-t6c-1-pushover-seed-operator.)
        let sinkSelection = AutorunSinkSelector.resolve()
        let driver = AutorunLoopDriver(
            database: SessionDatabase.shared,
            commandRunner: ProcessCommandRunner(),
            sink: sinkSelection.sink,
            supervisionPrompt: ProcessSupervisionPrompt()
        )

        // --dry-run: decompose + persist + print the plan; execute nothing.
        if dryRun {
            driver.dryRun(contracts: contracts)
            return
        }

        // Unattended-refusal precondition: refuse an unattended run when
        // Pushover is not seeded. Leg 4 resolves this from the real vault
        // probe (see the selector above), so an unattended run is allowed
        // ONLY once the operator has genuinely seeded the credential.
        let attendedOnTTY = isatty(STDIN_FILENO) == 1

        // Supervision conflict guard (LEG 2): `--supervise-first N>0` REQUIRES
        // an operator on the TTY — the spine will ask for a y/n. Refuse BEFORE
        // starting the run so an unattended `--supervise-first` never blocks
        // forever on stdin (or, with the fail-safe stdin reader, aborts on the
        // first EOF without the operator ever seeing the prompt).
        if superviseFirst > 0 && !attendedOnTTY {
            FileHandle.standardError.write(
                ("senkani autorun: --supervise-first requires an operator on the TTY; "
                    + "rerun attended or with --supervise-first 0\n").data(using: .utf8) ?? Data()
            )
            throw ExitCode.failure
        }

        let pushoverSeededForReal = sinkSelection.pushoverSeededForReal
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
        let allowList = TaskClass.parseAllowList(allowClasses ?? "")
        let result = driver.run(
            contracts: contracts,
            runId: runId,
            superviseFirst: superviseFirst,
            allowList: allowList
        )
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

/// The REAL `SupervisionPrompt` for the CLI (LEG 2): prints a one-line y/N
/// prompt for a supervised task and reads ONE line from stdin. Lives in the
/// CLI target (process/stdin I/O is wiring, not Core-pure spine logic — the
/// same placement rationale as `ProcessCommandRunner`).
///
/// FAIL-SAFE: only `y`/`yes` (case-insensitive, trimmed) advances. EVERYTHING
/// else — a bare newline, `n`, garbage, or EOF (nil from `readLine`) —
/// returns `.abort`. When supervision was explicitly requested, the loop must
/// never advance unattended, so an empty/EOF answer is treated as "stop".
struct ProcessSupervisionPrompt: SupervisionPrompt {
    /// Pure, directly-testable classification of a raw stdin answer line
    /// (or `nil` for EOF) into a `SupervisionAnswer`. FAIL-SAFE: only `y`/`yes`
    /// (trimmed, case-insensitive) → `.proceed`; a bare newline (`""`), `n`,
    /// any other string, and EOF (`nil`) → `.abort`. Extracted from the
    /// `readLine` call so the safety-critical answer mapping is unit-tested
    /// without touching stdin.
    static func classify(_ line: String?) -> SupervisionAnswer {
        guard let line else {
            // EOF — no operator answer. Fail safe: abort.
            return .abort
        }
        let answer = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (answer == "y" || answer == "yes") ? .proceed : .abort
    }

    func confirmAdvance(taskIndex: Int, total: Int, objective: String) -> SupervisionAnswer {
        FileHandle.standardOutput.write(
            "  [\(taskIndex + 1)/\(total)] \(objective) — commit? [y/N] ".data(using: .utf8) ?? Data()
        )
        return Self.classify(readLine(strippingNewline: true))
    }
}
