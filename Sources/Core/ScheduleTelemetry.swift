import Foundation

/// Records token_events for scheduled-task runs so they surface in the
/// Agent Timeline pane alongside interactive tool calls. Every event uses
/// `source = "schedule"` and one of three feature values
/// (`schedule_start`, `schedule_end`, `schedule_blocked`) so consumers can
/// filter and pair runs. `session_id` is `"schedule:{name}:{runId}"` —
/// start and end for the same run share the id so the pair is joinable
/// without a separate metadata column.
///
/// Reuses existing SessionDatabase + schema — no new tables.
public enum ScheduleTelemetry {

    /// Source value written to every schedule event.
    public static let source = "schedule"

    /// feature values for each event type.
    public static let featureStart = "schedule_start"
    public static let featureEnd = "schedule_end"
    public static let featureBlocked = "schedule_blocked"

    // MARK: - Test-only DB override (mirrors ScheduleStore.withTestDirs)

    nonisolated(unsafe) private static var _dbOverride: SessionDatabase?
    private static let testLock = NSLock()

    /// TEST ONLY: redirect telemetry writes to `db` for the duration of
    /// `body`. Holds `testLock` so concurrent callers serialize.
    public static func withTestDatabase<T>(_ db: SessionDatabase, _ body: () throws -> T) rethrows -> T {
        testLock.lock()
        let prior = _dbOverride
        _dbOverride = db
        defer {
            _dbOverride = prior
            testLock.unlock()
        }
        return try body()
    }

    private static var database: SessionDatabase {
        _dbOverride ?? .shared
    }

    // MARK: - Public API

    /// Stable pairing id for a single run's start + end (+ blocked) events.
    public static func sessionId(taskName: String, runId: String) -> String {
        "schedule:\(taskName):\(runId)"
    }

    /// Run-id format: `yyyyMMddHHmmss-<6 random lowercase-alnum>` in UTC.
    /// Matches `ScheduleWorktree.makeRunId` shape so a worktree-enabled run
    /// uses the same id for both telemetry and disk path.
    public static func makeRunId() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMddHHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        let ts = fmt.string(from: Date())
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var rand = ""
        for _ in 0..<6 {
            rand.append(alphabet.randomElement()!)
        }
        return "\(ts)-\(rand)"
    }

    /// Record a `schedule_start` event at the moment Schedule.Run begins
    /// executing the task command (after the budget gate + worktree
    /// setup, before `/bin/zsh -c task.command`).
    public static func recordStart(
        projectRoot: String,
        taskName: String,
        command: String,
        runId: String
    ) {
        database.recordTokenEvent(
            sessionId: sessionId(taskName: taskName, runId: runId),
            paneId: nil,
            projectRoot: projectRoot,
            source: source,
            toolName: nil,
            model: nil,
            inputTokens: 0,
            outputTokens: 0,
            savedTokens: 0,
            costCents: 0,
            feature: featureStart,
            command: "\(taskName): \(command)",
            modelTier: nil
        )
    }

    /// Record a `schedule_end` event after the subprocess exits. The
    /// `exitCode` is embedded in the event's `command` string so the
    /// Timeline pane shows it and tests can assert on substring.
    public static func recordEnd(
        projectRoot: String,
        taskName: String,
        runId: String,
        exitCode: Int32
    ) {
        let result = exitCode == 0 ? "success" : "failed: exit \(exitCode)"
        database.recordTokenEvent(
            sessionId: sessionId(taskName: taskName, runId: runId),
            paneId: nil,
            projectRoot: projectRoot,
            source: source,
            toolName: nil,
            model: nil,
            inputTokens: 0,
            outputTokens: 0,
            savedTokens: 0,
            costCents: 0,
            feature: featureEnd,
            command: "\(taskName): \(result)",
            modelTier: nil
        )
    }

    /// Record a `schedule_blocked` event when the budget gate rejects a
    /// run. No matching start/end pair is emitted — the blocked event is
    /// the only record the run happened. `reason` comes verbatim from
    /// `BudgetConfig.Decision.block(…)`.
    public static func recordBlocked(
        projectRoot: String,
        taskName: String,
        runId: String,
        reason: String
    ) {
        database.recordTokenEvent(
            sessionId: sessionId(taskName: taskName, runId: runId),
            paneId: nil,
            projectRoot: projectRoot,
            source: source,
            toolName: nil,
            model: nil,
            inputTokens: 0,
            outputTokens: 0,
            savedTokens: 0,
            costCents: 0,
            feature: featureBlocked,
            command: "\(taskName): budget_exceeded (\(reason))",
            modelTier: nil
        )
    }
}
