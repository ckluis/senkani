import Testing
import Foundation
import ArgumentParser
@testable import CLI
@testable import Core

/// `senkani schedule create --counter-cadence <expr>` writes the
/// `ScheduledTask` JSON via `ScheduleStore.save` with a `COUNTER:<event>:<N>`
/// sentinel `cronPattern` and `eventCounterCadence: <expr>`, and does NOT
/// generate a launchd plist or invoke `launchctl load` — counter cadences
/// fire from HookRouter post-tool reactions, not launchd.
///
/// `schedule-cli-counter-cadence-flag-2026-05-21` (Finding C-counter, split
/// from `schedule-amplification-guard-and-pane-not-wired-2026-05-17`).
@Suite("Schedule create — counter-cadence flag")
struct ScheduleCommandCounterCadenceTests {

    // MARK: - Source-level guard

    @Test("ScheduleCommand.Create exposes --counter-cadence and skips launchd for that branch")
    func sourceContainsCounterCadenceBranch() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests/SenkaniTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // <repo root>
            .appendingPathComponent("Sources/CLI/ScheduleCommand.swift")
        let src = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        #expect(src.contains("var counterCadence: String?"),
                "Schedule.Create must declare a counterCadence Option")
        #expect(src.contains("--counter-cadence"),
                "Help text or @Option must surface the --counter-cadence flag name (parsed by ArgumentParser via case-conversion)")
        #expect(src.contains("runCounterCadence"),
                "Schedule.Create must dispatch to a counter-cadence branch")
        // The counter-cadence branch must call ScheduleStore.save and
        // must NOT call PresetInstaller.install (which would write the plist).
        guard let ccBranchStart = src.range(of: "runCounterCadence(_ expression: String)") else {
            Issue.record("Missing runCounterCadence(_:) function body")
            return
        }
        let ccBranch = String(src[ccBranchStart.lowerBound...])
        // Cut at the closing brace of the file. Looking for substrings within
        // the branch body is enough to prove the design.
        #expect(ccBranch.contains("ScheduleStore.save(task)"),
                "counter-cadence branch must persist via ScheduleStore.save directly")
        // sentinelCronPattern is the documented marker.
        #expect(ccBranch.contains("sentinelCronPattern"),
                "counter-cadence branch must use CounterCadence.sentinelCronPattern for cronPattern")
        // Make sure the counter-cadence branch doesn't call PresetInstaller.install.
        // Scan only the runCounterCadence body — slice from its start to the next `private func` or end of file.
        let cutoff = ccBranch.range(of: "\n    private func ")?.lowerBound
            ?? ccBranch.range(of: "\n}\n")?.lowerBound
            ?? ccBranch.endIndex
        let bodyOnly = String(ccBranch[..<cutoff])
        #expect(!bodyOnly.contains("PresetInstaller.install"),
                "counter-cadence branch MUST NOT call PresetInstaller.install (no launchd plist)")
    }

    // MARK: - Behavioral: success writes JSON, skips plist

    @Test("--counter-cadence \"every 10 tool_calls\" writes JSON sentinel, no plist")
    func everyTenToolCallsWritesJsonAndSkipsPlist() throws {
        let tmpBase = NSTemporaryDirectory() + "senkani-counter-\(UUID().uuidString)"
        let tmpLaunch = NSTemporaryDirectory() + "senkani-counter-launch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpBase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tmpLaunch, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tmpBase)
            try? FileManager.default.removeItem(atPath: tmpLaunch)
        }

        let name = "counter-success-test"
        let create = try Schedule.Create.parse([
            "--name", name,
            "--counter-cadence", "every 10 tool_calls",
            "--command", "echo cc",
        ])

        var thrown: Error?
        ScheduleStore.withTestDirs(base: tmpBase, launchAgents: tmpLaunch) {
            do {
                try create.run()
            } catch {
                thrown = error
            }
        }
        #expect(thrown == nil, "counter-cadence with N=10 must succeed; got \(String(describing: thrown))")

        // JSON exists at <base>/<name>.json with the documented sentinel.
        let jsonPath = tmpBase + "/\(name).json"
        #expect(FileManager.default.fileExists(atPath: jsonPath),
                "JSON must be written for a successful counter-cadence schedule")

        let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ScheduledTask.self, from: data)

        #expect(decoded.cronPattern == "COUNTER:tool_call:10",
                "cronPattern must be the COUNTER:<event>:<N> sentinel. Got: \(decoded.cronPattern)")
        #expect(CounterCadence.isSentinel(decoded.cronPattern),
                "CounterCadence.isSentinel must recognize the written cronPattern")
        #expect(decoded.eventCounterCadence == "every 10 tool_calls",
                "eventCounterCadence must round-trip the original prose. Got: \(String(describing: decoded.eventCounterCadence))")

        // Plist must NOT be written.
        let plistPath = tmpLaunch + "/com.senkani.schedule.\(name).plist"
        #expect(!FileManager.default.fileExists(atPath: plistPath),
                "Plist MUST be absent for counter-cadence schedules. Found: \(plistPath)")

        // LaunchAgents dir must contain nothing for this schedule (assert
        // the entire directory has zero entries we wrote).
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: tmpLaunch)) ?? []
        #expect(entries.allSatisfy { !$0.contains(name) },
                "LaunchAgents dir must contain no entries referencing the counter schedule. Found: \(entries)")
    }

    // MARK: - Behavioral: amplification rejection

    @Test("--counter-cadence \"every 1 tool_call\" rejected at validate; no disk writes")
    func everyOneToolCallIsRejectedAtParseTimeWithNoDiskTrace() throws {
        let tmpBase = NSTemporaryDirectory() + "senkani-counter-amp-\(UUID().uuidString)"
        let tmpLaunch = NSTemporaryDirectory() + "senkani-counter-amp-launch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpBase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tmpLaunch, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tmpBase)
            try? FileManager.default.removeItem(atPath: tmpLaunch)
        }

        let name = "counter-amp-test"

        // validate() catches N < 2 at parse time — Schedule.Create.parse(_)
        // runs validate() via ArgumentParser. So .parse must throw.
        var thrown: Error?
        do {
            _ = try Schedule.Create.parse([
                "--name", name,
                "--counter-cadence", "every 1 tool_call",
                "--command", "echo amp",
            ])
        } catch {
            thrown = error
        }
        guard let err = thrown else {
            Issue.record("Schedule.Create.parse must throw for counter-cadence N=1")
            return
        }
        let desc = String(describing: err).lowercased()
        #expect(desc.contains("amplif") || desc.contains("amplification floor") || desc.contains("at or below"),
                "Thrown error must name the amplification floor reason. Got: \(desc)")

        // Filesystem must be clean — parse() throwing means run() never
        // executed, so no JSON, no plist.
        let jsonPath = tmpBase + "/\(name).json"
        let plistPath = tmpLaunch + "/com.senkani.schedule.\(name).plist"
        #expect(!FileManager.default.fileExists(atPath: jsonPath),
                "JSON MUST be absent after amplification rejection")
        #expect(!FileManager.default.fileExists(atPath: plistPath),
                "Plist MUST be absent after amplification rejection")
    }

    // MARK: - Behavioral: malformed expression

    @Test("--counter-cadence \"purple monkey dishwasher\" parse-rejected; no disk writes")
    func malformedExpressionIsRejected() throws {
        var thrown: Error?
        do {
            _ = try Schedule.Create.parse([
                "--name", "bad-cc",
                "--counter-cadence", "purple monkey dishwasher",
                "--command", "echo x",
            ])
        } catch {
            thrown = error
        }
        guard let err = thrown else {
            Issue.record("Schedule.Create.parse must throw on malformed counter-cadence expression")
            return
        }
        let desc = String(describing: err).lowercased()
        #expect(desc.contains("counter-cadence") || desc.contains("invalid"),
                "Thrown error must name the parse failure. Got: \(desc)")
    }

    // MARK: - Mutual exclusion

    @Test("--cron and --counter-cadence together are rejected")
    func bothFlagsTogetherRejected() throws {
        var thrown: Error?
        do {
            _ = try Schedule.Create.parse([
                "--name", "both",
                "--cron", "0 9 * * *",
                "--counter-cadence", "every 5 tool_calls",
                "--command", "echo x",
            ])
        } catch {
            thrown = error
        }
        guard let err = thrown else {
            Issue.record("Schedule.Create.parse must reject providing both --cron and --counter-cadence")
            return
        }
        let desc = String(describing: err).lowercased()
        #expect(desc.contains("mutually exclusive") || desc.contains("--cron and --counter-cadence"),
                "Thrown error must name the mutual exclusion. Got: \(desc)")
    }

    @Test("Neither --cron nor --counter-cadence is rejected")
    func neitherFlagRejected() throws {
        var thrown: Error?
        do {
            _ = try Schedule.Create.parse([
                "--name", "neither",
                "--command", "echo x",
            ])
        } catch {
            thrown = error
        }
        guard let err = thrown else {
            Issue.record("Schedule.Create.parse must reject when neither cadence flag is set")
            return
        }
        let desc = String(describing: err).lowercased()
        #expect(desc.contains("--cron") || desc.contains("--counter-cadence") || desc.contains("provide one"),
                "Thrown error must name the missing cadence flag. Got: \(desc)")
    }

    // MARK: - Sentinel helper round-trip

    @Test("CounterCadence.sentinelCronPattern and isSentinel round-trip")
    func sentinelHelperRoundTrip() {
        let cc = CounterCadence(eventName: "tool_call", everyN: 25)
        #expect(cc.sentinelCronPattern == "COUNTER:tool_call:25")
        #expect(CounterCadence.isSentinel(cc.sentinelCronPattern))
        #expect(!CounterCadence.isSentinel("0 9 * * *"))
        #expect(!CounterCadence.isSentinel("* * * * *"))
    }
}
