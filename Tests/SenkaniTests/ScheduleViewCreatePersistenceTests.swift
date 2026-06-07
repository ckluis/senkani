import Testing
@testable import Core
import Foundation

/// Guards the Schedules pane create-form persistence path
/// (`schedule-pane-create-form-cron-prose-no-launchd-load-2026-05-31`).
///
/// Before this fix, `ScheduleView.createSchedule()` persisted EVERY new
/// schedule via `ScheduleStore.save(task)` — JSON only, no launchd plist
/// — so a GUI-created cron/prose schedule was recorded but never fired.
/// The CLI's `runCron` / `runProse` (ScheduleCommand) instead route
/// through `PresetInstaller.install(task:)`, which also writes + loads the
/// plist. The create-form now mirrors that: cron + prose → install,
/// counter → save (HookRouter-driven, no plist).
///
/// The first test is a SOURCE guard (reads `ScheduleView.swift` as text);
/// the second is a behavioral round-trip asserting the install path the GUI
/// now uses writes both a JSON config and a launchd plist. Mirrors the
/// `ScheduleViewComposeModeTests` + `PresetInstallCommandTests` patterns.
@Suite("ScheduleView — create-form persists cron/prose via PresetInstaller (launchd plist)")
struct ScheduleViewCreatePersistenceTests {

    /// Resolve `SenkaniApp/Views/ScheduleView.swift` from this test file's
    /// location (Tests/SenkaniTests/<file>) up to the repo root.
    private static func scheduleViewSource() -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // Tests/SenkaniTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // <repo root>
            .appendingPathComponent("SenkaniApp/Views/ScheduleView.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - Source guard (acceptance #4 + #3)

    @Test("createSchedule routes cron + prose through PresetInstaller.install and counter through ScheduleStore.save")
    func createScheduleRoutesPersistenceByMode() {
        let src = Self.scheduleViewSource()
        #expect(!src.isEmpty, "ScheduleView.swift must be readable from the test")

        // The persistence switch combines cron + prose into one branch —
        // distinct from the task-construction switch, which handles each
        // mode separately (`case .cron:` / `case .prose:`).
        #expect(src.contains("case .cron, .prose:"),
                "create-form must persist cron + prose via a combined branch")
        #expect(src.contains("PresetInstaller.install(task: task)"),
                "cron/prose branch must persist via PresetInstaller.install")

        // Anchor on the install call (`ScheduleView` has several other
        // composeMode switches, so we locate the persistence switch by the
        // install it performs). The branch label immediately preceding the
        // install must be the combined cron/prose case — not counter.
        if let installRange = src.range(of: "_ = try PresetInstaller.install(task: task)") {
            let before = String(src[..<installRange.lowerBound])
            let lastCronProse = before.range(of: "case .cron, .prose:", options: .backwards)?.lowerBound
            let lastCounter = before.range(of: "case .counter:", options: .backwards)?.lowerBound
            #expect(lastCronProse != nil, "install must sit under a cron/prose branch")
            if let lastCronProse, let lastCounter {
                #expect(lastCronProse > lastCounter,
                        "the install must be in the cron/prose branch, not the counter branch")
            }
            // After the install, the counter branch persists via save (no plist).
            let after = String(src[installRange.upperBound...])
            if let counterRange = after.range(of: "case .counter:") {
                let counterBody = String(after[counterRange.upperBound...])
                #expect(counterBody.contains("try ScheduleStore.save(task)"),
                        "counter cadences must persist via ScheduleStore.save (no launchd plist)")
            }
        }

        // Install errors surface inline rather than silently dropping the
        // schedule (acceptance #3).
        #expect(src.contains("catch let error as PresetInstaller.InstallError"),
                "install errors must be caught as PresetInstaller.InstallError")
        #expect(src.contains("createError ="),
                "install errors must write the inline createError message")
    }

    // MARK: - Behavioral round-trip (acceptance #5)

    @Test("PresetInstaller.install round-trip yields both a JSON config and a launchd plist for a cron task")
    func installRoundTripWritesJSONAndPlist() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-gui-create-persistence-\(UUID().uuidString)")
        let base = tmp.appendingPathComponent("schedules").path
        let launch = tmp.appendingPathComponent("LaunchAgents").path
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: launch, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: base)
            try? FileManager.default.removeItem(atPath: launch)
        }

        try ScheduleStore.withTestDirs(base: base, launchAgents: launch) {
            // A cron task as the GUI create-form now builds it (cron mode).
            let task = ScheduledTask(
                name: "gui-cron-create",
                cronPattern: "0 9 * * *",
                command: "senkani digest",
                budgetLimitCents: nil,
                enabled: true
            )
            let result = try PresetInstaller.install(
                task: task,
                binaryPath: "/opt/senkani/senkani",
                loadWithLaunchctl: false
            )

            // JSON config landed (what the old ScheduleStore.save path did).
            let jsonPath = base + "/gui-cron-create.json"
            #expect(FileManager.default.fileExists(atPath: jsonPath),
                    "install must write the task JSON config")

            // launchd plist landed (the part the old GUI path was missing).
            #expect(result.plistPath == launch + "/com.senkani.schedule.gui-cron-create.plist")
            #expect(FileManager.default.fileExists(atPath: result.plistPath),
                    "install must write the launchd plist the GUI path now relies on")
            #expect(result.plistXML.contains("StartCalendarInterval"),
                    "plist must carry the launchd calendar interval")
            #expect(result.launchctlLoaded == false)
        }
    }
}
