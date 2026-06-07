import Testing
import Foundation
@testable import CLI
@testable import Core

/// `senkani schedule list` renders counter-cadence rows with the
/// `eventCounterCadence` prose, not the raw `COUNTER:<event>:<N>`
/// sentinel. Mirrors `SenkaniApp/Views/ScheduleView.swift:172`.
///
/// `schedule-cli-list-counter-cadence-display-2026-05-21` (split from
/// `schedule-cli-counter-cadence-flag-2026-05-21` defects-outside-criteria).
@Suite("Schedule list — counter-cadence SCHEDULE column")
struct ScheduleCommandListRenderTests {

    // MARK: - Source-level guard

    @Test("Schedule.ListTasks declares renderSchedule and run() calls it")
    func sourceContainsRenderSchedule() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests/SenkaniTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // <repo root>
            .appendingPathComponent("Sources/CLI/ScheduleCommand.swift")
        let src = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        #expect(src.contains("static func renderSchedule(for task: ScheduledTask) -> String"),
                "Schedule.ListTasks must declare renderSchedule(for:) helper")
        #expect(src.contains("Self.renderSchedule(for: task)"),
                "Schedule.ListTasks.run() must route the SCHEDULE column through renderSchedule")
        #expect(src.contains("task.eventCounterCadence"),
                "renderSchedule must consult eventCounterCadence before falling back to humanReadable")
    }

    // MARK: - Behavioral: counter row

    @Test("Counter-cadence row renders the prose, not the COUNTER: sentinel")
    func counterRowRendersProse() {
        let counterTask = ScheduledTask(
            name: "every-10-toolcalls",
            cronPattern: "COUNTER:tool_call:10",
            command: "echo hi",
            eventCounterCadence: "every 10 tool_calls"
        )
        let rendered = Schedule.ListTasks.renderSchedule(for: counterTask)
        #expect(!rendered.contains("COUNTER:"),
                "counter-cadence SCHEDULE column must NOT contain the raw `COUNTER:` sentinel. Got: \(rendered)")
        #expect(rendered.contains("every 10 tool_calls"),
                "counter-cadence SCHEDULE column must contain the operator's prose. Got: \(rendered)")
    }

    // MARK: - Behavioral: cron row regression guard

    @Test("Cron row keeps humanReadable rendering (regression guard)")
    func cronRowKeepsHumanReadable() {
        let cronTask = ScheduledTask(
            name: "daily-9am",
            cronPattern: "0 9 * * *",
            command: "echo morning"
        )
        let rendered = Schedule.ListTasks.renderSchedule(for: cronTask)
        let expected = CronToLaunchd.humanReadable("0 9 * * *")
        #expect(rendered == expected,
                "cron row must continue to render via CronToLaunchd.humanReadable. Got: \(rendered), expected: \(expected)")
        #expect(!rendered.contains("COUNTER:"),
                "cron row must not pick up any counter sentinel by accident. Got: \(rendered)")
    }

    // MARK: - Behavioral: empty counter falls back to humanReadable

    @Test("Empty eventCounterCadence string falls through to humanReadable")
    func emptyCounterFallsThrough() {
        let oddTask = ScheduledTask(
            name: "odd",
            cronPattern: "*/5 * * * *",
            command: "echo every5",
            eventCounterCadence: ""
        )
        let rendered = Schedule.ListTasks.renderSchedule(for: oddTask)
        #expect(rendered == CronToLaunchd.humanReadable("*/5 * * * *"),
                "empty counter string must not short-circuit the cron rendering. Got: \(rendered)")
    }

    // MARK: - End-to-end: ListTasks().run() over a temp ScheduleStore

    @Test("ListTasks().run() drives renderSchedule across a mixed task set without crashing")
    func runDrivesMixedTaskSet() throws {
        let tmpBase = NSTemporaryDirectory() + "senkani-list-\(UUID().uuidString)"
        let tmpLaunch = NSTemporaryDirectory() + "senkani-list-launch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpBase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tmpLaunch, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tmpBase)
            try? FileManager.default.removeItem(atPath: tmpLaunch)
        }

        var thrown: Error?
        ScheduleStore.withTestDirs(base: tmpBase, launchAgents: tmpLaunch) {
            do {
                // Persist one cron task + one counter task to the temp store.
                let cronTask = ScheduledTask(
                    name: "daily",
                    cronPattern: "0 9 * * *",
                    command: "echo daily"
                )
                let counterTask = ScheduledTask(
                    name: "ten-toolcalls",
                    cronPattern: "COUNTER:tool_call:10",
                    command: "echo cc",
                    eventCounterCadence: "every 10 tool_calls"
                )
                try ScheduleStore.save(cronTask)
                try ScheduleStore.save(counterTask)

                // Drive run() — it prints to stdout, which the test
                // runner captures. We're asserting it doesn't throw;
                // the rendering correctness is covered by the pure
                // renderer tests above.
                try Schedule.ListTasks().run()
            } catch {
                thrown = error
            }
        }
        #expect(thrown == nil,
                "Schedule.ListTasks().run() over mixed cron+counter tasks must not throw. Got: \(String(describing: thrown))")
    }
}
