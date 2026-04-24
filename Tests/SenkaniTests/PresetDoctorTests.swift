import Testing
@testable import Core
import Foundation

@Suite("PresetDoctor — surfaces missing prereqs for installed preset tasks")
struct PresetDoctorTests {

    @Test("Report flags a task that matches a shipped preset with missing probes")
    func reportFlagsMissingPrereqs() {
        let autoresearch = PresetCatalog.find("autoresearch")!
        let task = autoresearch.toScheduledTask(overrides: ["topic": "example"])

        PresetPrerequisiteCheck.withProbes([
            "senkani_search_web": false,
            "guard-research": false,
            "ollama": false
        ]) {
            let report = PresetDoctor.check(
                tasks: [task],
                presets: [autoresearch]
            )
            #expect(report.clean == false)
            #expect(report.byTask["autoresearch"]?.count == 3)
            #expect(PresetDoctor.summaryMessage(report) != nil)
        }
    }

    @Test("Report is clean when installed tasks have no matching shipped preset")
    func reportSkipsAdHocTasks() {
        let adHoc = ScheduledTask(
            name: "custom-backup",
            cronPattern: "0 4 * * *",
            command: "rsync ~ /mnt/backup"
        )
        let report = PresetDoctor.check(
            tasks: [adHoc],
            presets: PresetCatalog.shipped
        )
        #expect(report.clean)
        #expect(report.byTask.isEmpty)
        #expect(PresetDoctor.summaryMessage(report) == nil)
    }
}
