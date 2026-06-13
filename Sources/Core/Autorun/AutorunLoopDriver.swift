import Foundation

/// U.3 (LEG 1) — `AutorunLoopDriver`: the Core-pure spine of `senkani
/// autorun`. One-task-at-a-time loop with a per-task validation gate,
/// notification emission, and a dry-run mode — all driven through
/// INJECTED seams so the spine is unit-testable with NO real process,
/// network, or TTY.
///
/// ## Seams (Carmack — testable cut points)
///
///   - `CommandRunner`: runs a command string → `(exitCode, output)`.
///     Tests inject `MockCommandRunner` returning canned exit codes; the
///     CLI injects `ProcessCommandRunner` (the real launcher).
///   - `SessionDatabase` (the real `ValidationStore`): per task, each
///     command's result is written as a `validation_results` row
///     (`outcome` = "clean" when exit==0 else "advisory"). Writes are
///     async-dispatched to the DB queue, so the driver `flushWrites()`
///     BEFORE querying the rows back (the AutoValidate dual-write
///     precedent). Each run is scoped to a UNIQUE `sessionId`
///     (`autorun-<run-id>`) so prior runs' rows never bleed into this
///     run's gate.
///   - `NotificationSink`: on per-task success → `notifyDone`; on halt →
///     `notifyFailure`. Tests inject `MockNotificationSink`; the CLI
///     injects a `PushoverSink` (with a fake transport in leg 1).
///
/// ## The gate (Kleppmann — the loop's safety invariant)
///
/// A task PROCEEDS (and emits a commit-event `notifyDone`) only when
/// EVERY one of its commands wrote a "clean" validation row. The gate
/// commands run in order with CI-style short-circuit — the first
/// non-clean command halts the task immediately (this task's later
/// commands are NOT run, the way `swift test` is skipped once `swift
/// build` fails). A non-clean row HALTS the loop: the driver emits one
/// `notifyFailure` and STOPS — it does NOT advance to the next task. With
/// a mix of tasks, the loop stops at the FIRST failing task and leaves the
/// rest unrun.
///
/// ## Dry-run
///
/// `--dry-run` decomposes + persists contracts.json + PRINTS the plan
/// (each task + its gate) and returns WITHOUT executing any command and
/// WITHOUT real notification sends. The dry-run path never touches the
/// CommandRunner or the NotificationSink.
public struct AutorunLoopDriver: Sendable {

    private let database: SessionDatabase
    private let commandRunner: CommandRunner
    private let sink: NotificationSink

    public init(
        database: SessionDatabase,
        commandRunner: CommandRunner,
        sink: NotificationSink
    ) {
        self.database = database
        self.commandRunner = commandRunner
        self.sink = sink
    }

    /// The unique validation sessionId for a run. Scoping each run to its
    /// own session keeps prior runs' rows from bleeding into this run's
    /// gate query.
    public static func sessionId(runId: String) -> String {
        "autorun-\(runId)"
    }

    // MARK: - Unattended-refusal precondition

    /// Leg-1 unattended-refusal precondition. The loop REFUSES to run
    /// unattended (no operator on the TTY) when Pushover credentials are
    /// not seeded — overnight runs MUST be able to notify the operator of a
    /// commit or a halt. The refusal message names the seed command so the
    /// operator knows the exact remediation.
    ///
    /// Leg 1 ships only the refusal LOGIC + message; the real seed and
    /// transport are the operator remainder. `pushoverSeeded` is the
    /// injected fact "a credential is retrievable at send time" and
    /// `attendedOnTTY` is "an operator is present" (stdin is a tty).
    public static func unattendedRefusalReason(
        pushoverSeeded: Bool,
        attendedOnTTY: Bool
    ) -> String? {
        // An attended run (operator on the TTY) is always allowed — the
        // operator sees halts directly. Only an UNATTENDED run requires a
        // seeded Pushover credential.
        guard !attendedOnTTY else { return nil }
        guard !pushoverSeeded else { return nil }
        return "Refusing to run unattended: Pushover notifications are not seeded, "
            + "so overnight commit/halt events could not reach you. "
            + "Seed credentials with `senkani doctor --seed-pushover-key`, "
            + "or run attended (with stdin on a tty)."
    }

    // MARK: - Plan (dry-run)

    /// One line per task describing the task + its gate. Used by `--dry-run`
    /// (and as the human plan header for a live run).
    public func planLines(for contracts: [WorkstreamTaskContract]) -> [String] {
        var lines: [String] = []
        let total = contracts.count
        lines.append("autorun plan — \(total) task\(total == 1 ? "" : "s"):")
        for (i, c) in contracts.enumerated() {
            lines.append("  [\(i + 1)/\(total)] \(c.objective)")
            let gate = c.commands.isEmpty
                ? "(no gate commands — proceeds immediately)"
                : "gate: " + c.commands.joined(separator: " && ")
            lines.append("        \(gate)")
            if !c.fileScope.isEmpty {
                lines.append("        scope: " + c.fileScope.joined(separator: ", "))
            }
        }
        return lines
    }

    /// `--dry-run`: print the plan, execute NOTHING, send NO notifications.
    /// Returns the plan lines (also printed via `output`).
    @discardableResult
    public func dryRun(
        contracts: [WorkstreamTaskContract],
        output: (String) -> Void = { print($0) }
    ) -> [String] {
        let lines = planLines(for: contracts)
        for line in lines { output(line) }
        output("(dry run — no commands executed, no notifications sent)")
        return lines
    }

    // MARK: - Live run

    /// Per-task outcome of one live loop pass.
    public enum TaskOutcome: Equatable, Sendable {
        /// All gate commands clean → committed (a `notifyDone` was emitted).
        case committed(taskIndex: Int)
        /// A gate command was non-clean → halted (a `notifyFailure` was
        /// emitted). `failedCommand` is the first command that failed.
        case halted(taskIndex: Int, failedCommand: String, exitCode: Int32)
    }

    /// The result of a live run: the per-task outcomes in order. If a task
    /// halted, no later task ran (the array ends at the halted task).
    public struct RunResult: Equatable, Sendable {
        public let outcomes: [TaskOutcome]
        /// True iff every task in `contracts` committed (no halt).
        public let allCommitted: Bool

        public init(outcomes: [TaskOutcome], allCommitted: Bool) {
            self.outcomes = outcomes
            self.allCommitted = allCommitted
        }
    }

    /// Run the loop over `contracts`, gating each task on its commands and
    /// emitting notifications. Stops at the first halt.
    ///
    /// - Parameters:
    ///   - contracts: the tasks (decompose output).
    ///   - runId: scopes the validation sessionId (`autorun-<run-id>`).
    ///   - output: human progress sink (defaults to `print`).
    @discardableResult
    public func run(
        contracts: [WorkstreamTaskContract],
        runId: String,
        output: (String) -> Void = { print($0) }
    ) -> RunResult {
        let sessionId = Self.sessionId(runId: runId)
        var outcomes: [TaskOutcome] = []
        let total = contracts.count

        for (index, contract) in contracts.enumerated() {
            let taskLabel = "[\(index + 1)/\(total)]"
            let taskId = Self.shortTaskId(contract)
            output("\(taskLabel) \(contract.objective)")

            // Run the gate commands in order, writing one validation row
            // per command. A non-zero exit writes an "advisory" row (the
            // ValidationStore convention) and marks this task non-clean.
            //
            // SHORT-CIRCUIT (CI-gate semantics): once a command fails, the
            // task is already going to halt, so we do NOT run this task's
            // remaining commands (e.g. don't run `swift test` after `swift
            // build` failed). The rows for the commands that DID run are the
            // durable gate evidence; the loop halts at the task boundary.
            var firstFailure: (command: String, exitCode: Int32)?
            for command in contract.commands {
                let result = commandRunner.run(command)
                let outcome = result.exitCode == 0 ? "clean" : "advisory"
                database.insertValidationResult(
                    sessionId: sessionId,
                    filePath: Self.gateFilePath(contract),
                    validatorName: "autorun",
                    category: "autorun",
                    exitCode: result.exitCode,
                    rawOutput: result.output,
                    advisory: result.exitCode == 0
                        ? "command clean: \(command)"
                        : "command failed (exit \(result.exitCode)): \(command)",
                    durationMs: 0,
                    outcome: outcome,
                    reason: result.exitCode == 0 ? nil : "exit_\(result.exitCode)"
                )
                if result.exitCode != 0 {
                    firstFailure = (command, result.exitCode)
                    break
                }
            }

            // GATE: flush the async DB writes, then query this run's rows
            // back. all-clean ⇒ proceed; any non-clean ⇒ halt.
            database.flushWrites()

            if let failure = firstFailure {
                let reason = "\(taskId) halted: `\(failure.command)` exited \(failure.exitCode)"
                output("  HALT — \(reason)")
                NotificationFanout.deliver(
                    .notifyFailure(toolName: "autorun", reason: reason),
                    to: [sink]
                )
                outcomes.append(.halted(taskIndex: index, failedCommand: failure.command, exitCode: failure.exitCode))
                return RunResult(outcomes: outcomes, allCommitted: false)
            }

            // Defense in depth: re-read the rows for THIS task and confirm
            // none is non-clean. The query is scoped to this run's session,
            // so prior runs' rows cannot poison the gate.
            let nonClean = database
                .validationResults(sessionId: sessionId)
                .filter { $0.validatorName == "autorun" && $0.outcome != "clean" }
            if let bad = nonClean.first {
                let reason = "\(taskId) halted: validation row not clean (\(bad.outcome))"
                output("  HALT — \(reason)")
                NotificationFanout.deliver(
                    .notifyFailure(toolName: "autorun", reason: reason),
                    to: [sink]
                )
                outcomes.append(.halted(taskIndex: index, failedCommand: bad.advisory, exitCode: bad.exitCode))
                return RunResult(outcomes: outcomes, allCommitted: false)
            }

            // All-clean ⇒ proceed/commit-event.
            output("  committed")
            NotificationFanout.deliver(
                .notifyDone(toolName: "autorun", summary: "\(taskId) committed"),
                to: [sink]
            )
            outcomes.append(.committed(taskIndex: index))
        }

        return RunResult(outcomes: outcomes, allCommitted: true)
    }

    // MARK: - Helpers

    /// A short, human-facing task id derived from the contract id (first 8
    /// hex of the UUID). Used in notification summaries/reasons.
    static func shortTaskId(_ contract: WorkstreamTaskContract) -> String {
        "task-" + contract.id.uuidString.prefix(8).lowercased()
    }

    /// The `file_path` stamped on the gate's validation rows. The contract's
    /// first file-scope entry when present, else the short task id (the
    /// column is non-null in the store).
    static func gateFilePath(_ contract: WorkstreamTaskContract) -> String {
        contract.fileScope.first ?? shortTaskId(contract)
    }
}

// MARK: - CommandRunner seam

/// The result of running one gate command.
public struct CommandRunResult: Equatable, Sendable {
    /// The process exit code (0 == clean).
    public let exitCode: Int32
    /// Captured combined output (stdout, optionally stderr). May be nil
    /// when a runner does not capture output.
    public let output: String?

    public init(exitCode: Int32, output: String? = nil) {
        self.exitCode = exitCode
        self.output = output
    }
}

/// Runs a command string and reports its exit code + captured output. The
/// loop driver's ONLY process seam — the spine never launches a process
/// directly, so tests inject a mock and the spine stays Core-pure.
public protocol CommandRunner: Sendable {
    /// Run `command` (a shell-style command line) to completion.
    func run(_ command: String) -> CommandRunResult
}

/// Test command runner. Returns canned results per command (or a default),
/// and records every command it was asked to run, in order. Thread-safe.
public final class MockCommandRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _ran: [String] = []
    /// Exact-match canned results keyed by the command string.
    private let canned: [String: CommandRunResult]
    /// Result returned for a command with no canned entry.
    private let defaultResult: CommandRunResult

    public init(
        canned: [String: CommandRunResult] = [:],
        defaultResult: CommandRunResult = CommandRunResult(exitCode: 0, output: nil)
    ) {
        self.canned = canned
        self.defaultResult = defaultResult
    }

    public var ran: [String] {
        lock.lock(); defer { lock.unlock() }
        return _ran
    }

    public func run(_ command: String) -> CommandRunResult {
        lock.lock()
        _ran.append(command)
        lock.unlock()
        return canned[command] ?? defaultResult
    }
}
