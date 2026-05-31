import Testing
import Foundation

/// Source-level guard for the Schedules pane create-form compose modes
/// (`schedule-senkaniapp-pane-2026-05-21-a-1`). The create-form gained
/// prose / counter / cron compose modes, a live AmplificationGuard
/// verdict banner, a CronPreview next-fires preview, and confirm-gating.
///
/// These are SOURCE guards (read `ScheduleView.swift` as text and assert
/// the declarations exist) rather than rendered-UI assertions —
/// body-composition validation is the Cowork walk in child a-2. The
/// guard catches a regression where any of the new compose surfaces is
/// removed or the gating is loosened. Mirrors the
/// `ScheduleCommandListRenderTests` `#filePath`-rooted pattern.
@Suite("ScheduleView — create-form compose modes (a-1)")
struct ScheduleViewComposeModeTests {

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

    // MARK: - New compose-mode surfaces

    @Test("Create-form declares prose/counter/cron compose modes, verdict banner, next-fires preview, and confirm-gating")
    func createFormDeclaresComposeSurfaces() {
        let src = Self.scheduleViewSource()
        #expect(!src.isEmpty, "ScheduleView.swift must be readable from the test")

        // (1) Three-way compose-mode toggle.
        #expect(src.contains("enum ComposeMode"),
                "create-form must declare a ComposeMode enum")
        #expect(src.contains("case prose") && src.contains("case counter") && src.contains("case cron"),
                "ComposeMode must cover prose, counter, and cron")
        #expect(src.contains("pickerStyle(.segmented)"),
                "compose-mode toggle must be a segmented picker")

        // (2) Prose mode compiles via the rule+null composite compiler,
        //     with a live compiled-cron preview.
        #expect(src.contains("CompositeProseCadenceCompiler"),
                "prose mode must compile via CompositeProseCadenceCompiler")
        #expect(src.contains("RuleBasedProseCadenceCompiler") && src.contains("NullProseCadenceCompiler"),
                "prose compiler must wire the rule arm + Null MLX arm (app does not link the CLI subprocess arm)")
        #expect(src.contains("compiledProseCron"),
                "prose mode must surface a live compiled-cron preview")

        // (3) Counter mode parses via CounterCadence.
        #expect(src.contains("CounterCadence.parse"),
                "counter mode must parse the expression via CounterCadence.parse")
        #expect(src.contains("sentinelCronPattern"),
                "counter schedules must persist the COUNTER: sentinel cron")

        // (4) Cron mode keeps the human-readable preview.
        #expect(src.contains("CronToLaunchd.humanReadable"),
                "cron + prose modes must show a human-readable cron preview")

        // (5) AmplificationGuard verdict banner — red/green.
        #expect(src.contains("amplificationBanner"),
                "create-form must declare an amplification verdict banner")
        #expect(src.contains("checkmark.circle.fill") && src.contains("exclamationmark.triangle.fill"),
                "verdict banner must use distinct ok (green check) and amplification (red triangle) glyphs")

        // (6) Next-fires preview from CronPreview.nextFires.
        #expect(src.contains("CronPreview.nextFires"),
                "create-form must preview next fires via CronPreview.nextFires")
        #expect(src.contains("nextFiresPreview"),
                "create-form must declare a next-fires preview view")

        // (7) Confirm-gating on AmplificationGuard.validate, with override.
        #expect(src.contains("AmplificationGuard.validate"),
                "create gate must consult AmplificationGuard.validate")
        #expect(src.contains("overrideAmplification"),
                "an amplification verdict must be overridable before Create is allowed")
        #expect(src.contains("var canCreate") && src.contains("disabled(!canCreate)"),
                "Create button must be gated by canCreate (which blocks unoverridden .amplification)")
    }

    // MARK: - Regression: existing list / toggle / delete unchanged

    @Test("Existing list, toggle, and delete behavior is preserved")
    func existingBehaviorPreserved() {
        let src = Self.scheduleViewSource()
        #expect(!src.isEmpty, "ScheduleView.swift must be readable from the test")

        #expect(src.contains("private var taskListView"),
                "task list view must still exist")
        #expect(src.contains("func toggleTask"),
                "enable/disable toggle action must still exist")
        #expect(src.contains("func removeTask"),
                "delete action must still exist")
        #expect(src.contains("ScheduleStore.save") && src.contains("ScheduleStore.remove"),
                "persistence via ScheduleStore.save/remove must be unchanged")
        #expect(src.contains("ScheduleStore.list"),
                "task loading via ScheduleStore.list must be unchanged")
    }
}
