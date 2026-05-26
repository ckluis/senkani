import Testing
import Foundation
import ArgumentParser
@testable import CLI
@testable import Core

/// `senkani schedule create` now refuses crons whose first two fires are
/// at or below `AmplificationGuard.defaultMinIntervalSeconds` (60s). The
/// wiring is at `Sources/CLI/ScheduleCommand.swift::Schedule.Create.run()`.
///
/// `schedule-amplification-guard-and-pane-not-wired-2026-05-17` (Finding
/// A) — pre-fix the guard had zero production callers and
/// `senkani schedule create --cron '* * * * *' --command echo` was
/// accepted silently. Behavioral test below drives `Schedule.Create` end-
/// to-end against `ScheduleStore.withTestDirs` and asserts that the
/// rejection leaves the filesystem clean (no JSON, no plist).
@Suite("Schedule create — AmplificationGuard wiring")
struct ScheduleCommandAmplificationTests {

    // MARK: - Source-level guard

    @Test("ScheduleCommand.Create.run() calls AmplificationGuard.validate before disk writes")
    func runCallsAmplificationGuardBeforeWrites() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests/SenkaniTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // <repo root>
            .appendingPathComponent("Sources/CLI/ScheduleCommand.swift")
        let src = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        // The `AmplificationGuard.validate(cron:counter:)` call must
        // appear inside `Create.run()` BEFORE the `PresetInstaller.install`
        // call. The simplest robust check is that both markers are
        // present and the guard comes first textually.
        guard let guardRange = src.range(of: "AmplificationGuard.validate(cron: cron, counter: nil)"),
              let installRange = src.range(of: "PresetInstaller.install(task: task)")
        else {
            Issue.record("Expected AmplificationGuard.validate + PresetInstaller.install markers in ScheduleCommand.swift")
            return
        }
        #expect(guardRange.lowerBound < installRange.lowerBound,
                "AmplificationGuard.validate must run BEFORE PresetInstaller.install so a rejected schedule leaves no JSON / plist on disk.")
    }

    // MARK: - Behavioral: fast-firing cron is refused

    @Test("schedule create with `* * * * *` is refused; JSON + plist absent")
    func everyMinuteCronIsRefusedAndLeavesNoDiskTrace() async throws {
        let tmpBase = NSTemporaryDirectory() + "senkani-amplification-\(UUID().uuidString)"
        let tmpLaunch = NSTemporaryDirectory() + "senkani-amplification-launch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpBase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tmpLaunch, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tmpBase)
            try? FileManager.default.removeItem(atPath: tmpLaunch)
        }

        let name = "amplification-reject-test"
        let create = try Schedule.Create.parse([
            "--name", name,
            "--cron", "* * * * *",
            "--command", "echo amp",
        ])

        var thrown: Error?
        await ScheduleStore.withTestDirs(base: tmpBase, launchAgents: tmpLaunch) {
            do {
                try await create.run()
            } catch {
                thrown = error
            }
        }

        // The wiring must throw ValidationError (ArgumentParser's
        // structured user-facing error type).
        guard let err = thrown else {
            Issue.record("Schedule.Create.run() must throw for amplifying cron `* * * * *`")
            return
        }
        let desc = String(describing: err)
        #expect(desc.lowercased().contains("amplif") || desc.lowercased().contains("amplification floor"),
                "Thrown error must name the amplification reason. Got: \(desc)")

        // Filesystem must be clean — no JSON, no plist.
        let jsonPath = tmpBase + "/\(name).json"
        let plistPath = tmpLaunch + "/com.senkani.schedule.\(name).plist"
        #expect(!FileManager.default.fileExists(atPath: jsonPath),
                "JSON file at \(jsonPath) MUST be absent after amplification rejection.")
        #expect(!FileManager.default.fileExists(atPath: plistPath),
                "Plist file at \(plistPath) MUST be absent after amplification rejection.")
    }

    // MARK: - AmplificationGuard semantic — boundary case (gap == floor)

    @Test("AmplificationGuard now rejects gap == floor (was strict <, now <=)")
    func boundaryCaseGapEqualsFloorRejects() {
        // `* * * * *` produces successive fires 60s apart, which is
        // exactly `defaultMinIntervalSeconds`. Pre-fix the guard used
        // strict `<` and admitted this case; the 2026-05-21 fix moved
        // to `<=` so the operator's reproduction case from the surface-
        // pass walk now refuses up front instead of being silently
        // clamped to 1 fire / 60s by the rate limiter downstream.
        let verdict = AmplificationGuard.validate(cron: "* * * * *", counter: nil)
        if case .amplification(let reason, let floor) = verdict {
            #expect(floor == AmplificationGuard.defaultMinIntervalSeconds,
                    "amplification verdict's floor must match the default (\(AmplificationGuard.defaultMinIntervalSeconds)s)")
            #expect(reason.contains("at or below"),
                    "Reason text must reflect the `<=` semantic with `at or below`. Got: \(reason)")
        } else {
            Issue.record("expected .amplification for `* * * * *` (60s gap == floor), got \(verdict)")
        }
    }

    @Test("AmplificationGuard still passes well-above-floor crons (regression check)")
    func dailyCronStillPasses() {
        let verdict = AmplificationGuard.validate(cron: "0 9 * * *", counter: nil)
        #expect(verdict == .ok,
                "Daily 9am cron (86400s gap) must still pass — the `<=` change does not over-reject.")
    }

    // MARK: - Behavioral: preset install with amplifying --cron override

    /// `schedule-preset-install-amplification-guard-not-wired-2026-05-21` —
    /// the `Schedule.Preset.Install` subcommand calls
    /// `PresetInstaller.install` and used to bypass AmplificationGuard. An
    /// operator override of `--cron '* * * * *'` against a shipped preset
    /// silently accepted, despite the sibling `Create.run()` wiring shipped
    /// 2026-05-21. This test drives `Preset.Install` end-to-end and asserts
    /// the same refusal + zero-disk-trace contract.
    @Test("schedule preset install with `--cron * * * * *` override is refused; JSON + plist absent")
    func presetInstallEveryMinuteCronOverrideIsRefusedAndLeavesNoDiskTrace() throws {
        let tmpBase = NSTemporaryDirectory() + "senkani-preset-amplification-\(UUID().uuidString)"
        let tmpLaunch = NSTemporaryDirectory() + "senkani-preset-amplification-launch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpBase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: tmpLaunch, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tmpBase)
            try? FileManager.default.removeItem(atPath: tmpLaunch)
        }

        let presetName = "log-rotation"
        let install = try Schedule.Preset.Install.parse([
            presetName,
            "--cron", "* * * * *",
        ])

        var thrown: Error?
        ScheduleStore.withTestDirs(base: tmpBase, launchAgents: tmpLaunch) {
            do {
                try install.run()
            } catch {
                thrown = error
            }
        }

        guard let err = thrown else {
            Issue.record("Schedule.Preset.Install.run() must throw for amplifying cron override `* * * * *`")
            return
        }
        let desc = String(describing: err)
        #expect(desc.lowercased().contains("amplif") || desc.lowercased().contains("amplification floor"),
                "Thrown error must name the amplification reason. Got: \(desc)")

        // Filesystem must be clean — no JSON, no plist for the preset's name.
        let jsonPath = tmpBase + "/\(presetName).json"
        let plistPath = tmpLaunch + "/com.senkani.schedule.\(presetName).plist"
        #expect(!FileManager.default.fileExists(atPath: jsonPath),
                "JSON file at \(jsonPath) MUST be absent after preset amplification rejection.")
        #expect(!FileManager.default.fileExists(atPath: plistPath),
                "Plist file at \(plistPath) MUST be absent after preset amplification rejection.")
    }

    // MARK: - Source-level guard: Preset.Install wiring

    @Test("ScheduleCommand.Preset.Install.run() calls AmplificationGuard.validate before disk writes")
    func presetInstallRunCallsAmplificationGuardBeforeWrites() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests/SenkaniTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // <repo root>
            .appendingPathComponent("Sources/CLI/ScheduleCommand.swift")
        let src = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        // Find the start of the Install struct body so we scope the
        // marker search to that subcommand — the file also contains the
        // identical `Create.runCron()` wiring, which would otherwise
        // satisfy this check trivially without the new wiring.
        guard let installStructRange = src.range(of: "struct Install: ParsableCommand") else {
            Issue.record("Could not locate `struct Install` in ScheduleCommand.swift")
            return
        }
        let installSlice = String(src[installStructRange.lowerBound...])

        guard let guardRange = installSlice.range(of: "AmplificationGuard.validate(cron: task.cronPattern, counter: nil)"),
              let installCallRange = installSlice.range(of: "PresetInstaller.install(task: task)")
        else {
            Issue.record("Expected AmplificationGuard.validate + PresetInstaller.install markers in Preset.Install body")
            return
        }
        #expect(guardRange.lowerBound < installCallRange.lowerBound,
                "AmplificationGuard.validate must run BEFORE PresetInstaller.install in Preset.Install.run() so a rejected preset leaves no JSON / plist on disk.")
    }
}
