import Testing
import Foundation
import ArgumentParser
@testable import CLI
@testable import Core

/// `senkani schedule create --prose` (schedule-cli-prose-flag-2026-05-21,
/// Finding C-prose). `Schedule.Create` is now `AsyncParsableCommand`; the
/// `--prose` path compiles the phrase to a cron via an injectable
/// `ProseCadenceCompiler`, runs it through `CronToLaunchd.convert` +
/// `AmplificationGuard`, and persists a `ScheduledTask` with the
/// NaturalLanguageSchedule fields.
///
/// `.serialized` because the tests mutate two process-global seams:
/// `Schedule.Create.proseCompilerFactory` and `ScheduleStore`'s test-dir
/// overrides.
@Suite("Schedule create — --prose wiring", .serialized)
struct ScheduleCommandProseTests {

    /// Restore the production compiler factory after each test's override.
    private func withMockCompiler<T>(
        _ compiler: @autoclosure @escaping @Sendable () -> any ProseCadenceCompiler,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let prior = Schedule.Create.proseCompilerFactory
        Schedule.Create.proseCompilerFactory = compiler
        defer { Schedule.Create.proseCompilerFactory = prior }
        return try await body()
    }

    // MARK: - (d) successful prose path writes the expected ScheduledTask

    @Test("--prose with a Mock compiler persists all NaturalLanguageSchedule fields")
    func proseCreateWritesScheduledTaskWithNLFields() async throws {
        let tmpBase = NSTemporaryDirectory() + "senkani-prose-\(UUID().uuidString)"
        let tmpLaunch = NSTemporaryDirectory() + "senkani-prose-launch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpBase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tmpLaunch, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tmpBase)
            try? FileManager.default.removeItem(atPath: tmpLaunch)
        }

        let name = "prose-create-test"
        let proseText = "every weekday at 9am"

        try await withMockCompiler(MockProseCadenceCompiler(constantCron: "0 9 * * 1,2,3,4,5")) {
            let create = try Schedule.Create.parse([
                "--name", name,
                "--prose", proseText,
                "--locale", "en-US",
                "--command", "senkani learn",
            ])

            try await ScheduleStore.withTestDirs(base: tmpBase, launchAgents: tmpLaunch) {
                try await create.run()
            }

            // Read the persisted task back from the temp dir.
            let loaded = ScheduleStore.withTestDirs(base: tmpBase, launchAgents: tmpLaunch) {
                ScheduleStore.load(name)
            }
            guard let task = loaded else {
                Issue.record("expected ScheduledTask `\(name)` to be persisted")
                return
            }
            #expect(task.proseCadence == proseText)
            #expect(task.compiledCadence == "0 9 * * 1,2,3,4,5")
            #expect(task.cronPattern == "0 9 * * 1,2,3,4,5")
            #expect(task.locale == "en-US")
            #expect(task.eventCounterCadence == nil)
            #expect(task.command == "senkani learn")
        }

        // The launchd plist was generated (real cron schedule).
        let plistPath = tmpLaunch + "/com.senkani.schedule.\(name).plist"
        #expect(FileManager.default.fileExists(atPath: plistPath),
                "Plist at \(plistPath) MUST exist after a successful prose create.")
    }

    // MARK: - (e) compiler error path leaves zero disk trace

    @Test("--prose with an unavailable compiler refuses; JSON + plist absent")
    func proseCreateUnavailableLeavesNoDiskTrace() async throws {
        let tmpBase = NSTemporaryDirectory() + "senkani-prose-unavail-\(UUID().uuidString)"
        let tmpLaunch = NSTemporaryDirectory() + "senkani-prose-unavail-launch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpBase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tmpLaunch, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tmpBase)
            try? FileManager.default.removeItem(atPath: tmpLaunch)
        }

        let name = "prose-unavailable-test"

        var thrown: Error?
        try await withMockCompiler(NullProseCadenceCompiler()) {
            let create = try Schedule.Create.parse([
                "--name", name,
                "--prose", "every weekday at 9am",
                "--locale", "en-US",
                "--command", "senkani learn",
            ])
            await ScheduleStore.withTestDirs(base: tmpBase, launchAgents: tmpLaunch) {
                do {
                    try await create.run()
                } catch {
                    thrown = error
                }
            }
        }

        guard let err = thrown else {
            Issue.record("Schedule.Create.run() must throw when the prose compiler is unavailable")
            return
        }
        let desc = String(describing: err).lowercased()
        #expect(desc.contains("--cron") || desc.contains("model"),
                "Thrown error must point the operator at a recovery path. Got: \(desc)")

        let jsonPath = tmpBase + "/\(name).json"
        let plistPath = tmpLaunch + "/com.senkani.schedule.\(name).plist"
        #expect(!FileManager.default.fileExists(atPath: jsonPath),
                "JSON at \(jsonPath) MUST be absent after a compiler-error refusal.")
        #expect(!FileManager.default.fileExists(atPath: plistPath),
                "Plist at \(plistPath) MUST be absent after a compiler-error refusal.")
    }

    // MARK: - three-way XOR validation

    @Test("validate() rejects zero cadences and any pair/triple")
    func threeWayXORValidation() {
        // Zero cadences.
        #expect(throws: (any Error).self) {
            _ = try Schedule.Create.parse(["--name", "x", "--command", "echo"])
        }
        // --cron + --prose.
        #expect(throws: (any Error).self) {
            _ = try Schedule.Create.parse([
                "--name", "x", "--command", "echo",
                "--cron", "0 9 * * *", "--prose", "daily",
            ])
        }
        // --counter-cadence + --prose.
        #expect(throws: (any Error).self) {
            _ = try Schedule.Create.parse([
                "--name", "x", "--command", "echo",
                "--counter-cadence", "every 10 tool_calls", "--prose", "daily",
            ])
        }
        // All three.
        #expect(throws: (any Error).self) {
            _ = try Schedule.Create.parse([
                "--name", "x", "--command", "echo",
                "--cron", "0 9 * * *", "--counter-cadence", "every 10 tool_calls", "--prose", "daily",
            ])
        }
        // Exactly one (--prose) parses cleanly.
        #expect(throws: Never.self) {
            _ = try Schedule.Create.parse([
                "--name", "x", "--command", "echo", "--prose", "daily",
            ])
        }
    }

    @Test("--prose with a non-English locale refuses via the real compiler; no disk trace")
    func proseNonEnglishLocaleRefusesNoDiskTrace() async throws {
        let tmpBase = NSTemporaryDirectory() + "senkani-prose-locale-\(UUID().uuidString)"
        let tmpLaunch = NSTemporaryDirectory() + "senkani-prose-locale-launch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpBase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tmpLaunch, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tmpBase)
            try? FileManager.default.removeItem(atPath: tmpLaunch)
        }

        let name = "prose-fr-locale-test"
        var thrown: Error?
        // Real RuleBasedProseCadenceCompiler (default factory).
        let create = try Schedule.Create.parse([
            "--name", name,
            "--prose", "every weekday at 9am",
            "--locale", "fr-FR",
            "--command", "senkani learn",
        ])
        await ScheduleStore.withTestDirs(base: tmpBase, launchAgents: tmpLaunch) {
            do {
                try await create.run()
            } catch {
                thrown = error
            }
        }

        #expect(thrown != nil, "non-English locale must refuse")
        #expect(String(describing: thrown).contains("en-US"))
        #expect(!FileManager.default.fileExists(atPath: tmpBase + "/\(name).json"))
        #expect(!FileManager.default.fileExists(atPath: tmpLaunch + "/com.senkani.schedule.\(name).plist"))
    }
}
