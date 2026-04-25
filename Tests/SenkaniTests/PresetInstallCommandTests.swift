import Testing
@testable import Core
import Foundation

@Suite("PresetInstaller — plist generation + placeholder substitution")
struct PresetInstallCommandTests {

    private func makeTempDirs() -> (base: String, launchAgents: String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-preset-install-\(UUID().uuidString)")
        let base = tmp.appendingPathComponent("schedules").path
        let launch = tmp.appendingPathComponent("LaunchAgents").path
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: launch, withIntermediateDirectories: true)
        return (base, launch)
    }

    @Test("Install produces a launchd plist whose XML references the task name + binary")
    func installProducesPlist() throws {
        let (base, launch) = makeTempDirs()
        defer {
            try? FileManager.default.removeItem(atPath: base)
            try? FileManager.default.removeItem(atPath: launch)
        }

        try ScheduleStore.withTestDirs(base: base, launchAgents: launch) {
            let preset = PresetCatalog.find("log-rotation")!
            let task = preset.toScheduledTask()
            let result = try PresetInstaller.install(
                task: task,
                binaryPath: "/opt/senkani/senkani",
                loadWithLaunchctl: false
            )

            #expect(result.plistPath == launch + "/com.senkani.schedule.log-rotation.plist")
            #expect(result.plistXML.contains("/opt/senkani/senkani"))
            #expect(result.plistXML.contains("<string>log-rotation</string>"))
            #expect(result.plistXML.contains("StartCalendarInterval"))
            #expect(result.launchctlLoaded == false)

            // JSON config also landed.
            let jsonPath = base + "/log-rotation.json"
            #expect(FileManager.default.fileExists(atPath: jsonPath))
        }
    }

    @Test("Placeholder `<topic>` is substituted into the stored command")
    func topicPlaceholderIsSubstituted() throws {
        let (base, launch) = makeTempDirs()
        defer {
            try? FileManager.default.removeItem(atPath: base)
            try? FileManager.default.removeItem(atPath: launch)
        }

        try ScheduleStore.withTestDirs(base: base, launchAgents: launch) {
            let preset = PresetCatalog.find("autoresearch")!
            let task = preset.toScheduledTask(overrides: ["topic": "ai workstation v7"])
            _ = try PresetInstaller.install(
                task: task,
                binaryPath: "/opt/senkani/senkani",
                loadWithLaunchctl: false
            )
            let loaded = ScheduleStore.load("autoresearch")
            #expect(loaded?.command.contains("ai workstation v7") == true)
            #expect(loaded?.command.contains("<topic>") == false)
        }
    }

    @Test("Budget override lands on the stored task")
    func budgetOverrideLands() throws {
        let (base, launch) = makeTempDirs()
        defer {
            try? FileManager.default.removeItem(atPath: base)
            try? FileManager.default.removeItem(atPath: launch)
        }

        try ScheduleStore.withTestDirs(base: base, launchAgents: launch) {
            let preset = PresetCatalog.find("morning-brief")!
            let task = preset.toScheduledTask(budgetOverride: 50)
            _ = try PresetInstaller.install(
                task: task,
                binaryPath: "/opt/senkani/senkani",
                loadWithLaunchctl: false
            )
            let loaded = ScheduleStore.load("morning-brief")
            #expect(loaded?.budgetLimitCents == 50)
        }
    }

    @Test("Invalid cron in the preset surfaces as InstallError.invalidCronPattern")
    func invalidCronThrows() throws {
        let (base, launch) = makeTempDirs()
        defer {
            try? FileManager.default.removeItem(atPath: base)
            try? FileManager.default.removeItem(atPath: launch)
        }

        try ScheduleStore.withTestDirs(base: base, launchAgents: launch) {
            let task = ScheduledTask(
                name: "broken",
                cronPattern: "not-a-cron",
                command: "echo hi"
            )
            #expect(throws: PresetInstaller.InstallError.self) {
                _ = try PresetInstaller.install(
                    task: task,
                    binaryPath: "/opt/senkani/senkani",
                    loadWithLaunchctl: false
                )
            }
        }
    }
}
