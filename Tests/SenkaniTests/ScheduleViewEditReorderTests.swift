import Testing
import Foundation

/// Source-level guard for the Schedules pane edit-in-place, drag-reorder,
/// and validation-tooltip surfaces (`schedule-senkaniapp-pane-2026-05-21-a-2`).
/// The create-form gained: selecting an existing schedule re-opens a-1's
/// compose surface PREFILLED with its cadence and saving UPDATES it via
/// ScheduleStore; the list supports drag-reorder persisted via ScheduleStore;
/// and the compose fields carry inline validation tooltips surfacing the
/// AmplificationGuard rationale and any compile error.
///
/// These are SOURCE guards (read `ScheduleView.swift` as text and assert the
/// declarations exist) rather than rendered-UI assertions — body-composition
/// and the real-machine walk are the Cowork round for a-2. The guard catches a
/// regression where any of the edit/reorder/tooltip surfaces is removed or the
/// gating is loosened. Mirrors the `ScheduleViewComposeModeTests` and
/// `ScheduleViewCreatePersistenceTests` `#filePath`-rooted patterns.
@Suite("ScheduleView — edit-in-place, reorder, validation tooltips (a-2)")
struct ScheduleViewEditReorderTests {

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

    // MARK: - Acceptance #1: edit-in-place

    @Test("Selecting an existing schedule opens the prefilled compose surface and saving updates it via ScheduleStore")
    func declaresEditInPlace() {
        let src = Self.scheduleViewSource()
        #expect(!src.isEmpty, "ScheduleView.swift must be readable from the test")

        // An editing-mode flag + prefill entry point.
        #expect(src.contains("editingName"),
                "edit mode must track the schedule being edited (editingName)")
        #expect(src.contains("var isEditing"),
                "create-form must derive an isEditing flag from editingName")
        #expect(src.contains("func beginEdit"),
                "selecting an existing row must call beginEdit to prefill the compose surface")

        // beginEdit must prefill the a-1 compose fields from the task so the
        // surface opens with the schedule's CURRENT cadence.
        #expect(src.contains("newProse = prose") || src.contains("newProse = task"),
                "edit must prefill the prose cadence field")
        #expect(src.contains("newCounter = counter") || src.contains("newCounter = task"),
                "edit must prefill the counter cadence field")
        #expect(src.contains("newCustomCron = cron") || src.contains("newCustomCron = task"),
                "edit must prefill a custom-cron schedule back into the form")

        // The edit must re-use a-1's compile + gate (no second persistence
        // path): the same AmplificationGuard gate and the same
        // PresetInstaller.install / ScheduleStore.save routing.
        #expect(src.contains("AmplificationGuard.validate"),
                "the edit save must re-run the AmplificationGuard gate (reuse a-1's path)")
        #expect(src.contains("PresetInstaller.install"),
                "cron/prose edits must persist via the same PresetInstaller.install path as create")
        #expect(src.contains("ScheduleStore.load"),
                "edit must load the existing row to preserve its lifecycle fields")

        // The name (file id) is locked while editing so a re-save overwrites
        // the same JSON in place rather than orphaning the old file.
        #expect(src.contains("disabled(isEditing)"),
                "the name field must be locked while editing (it is the file id)")
    }

    // MARK: - Acceptance #2: drag-reorder persisted via ScheduleStore

    @Test("Schedule list supports drag-reorder persisted via ScheduleStore")
    func declaresDragReorder() {
        let src = Self.scheduleViewSource()
        #expect(!src.isEmpty, "ScheduleView.swift must be readable from the test")

        #expect(src.contains(".onMove"),
                "the task list ForEach must declare an .onMove drag-reorder handler")
        #expect(src.contains("func moveTasks"),
                "drag-reorder must be handled by a moveTasks action")
        #expect(src.contains("move(fromOffsets:") && src.contains("toOffset:"),
                "moveTasks must reorder the tasks array via move(fromOffsets:toOffset:)")
        #expect(src.contains("ScheduleStore.save"),
                "the reorder must be persisted via ScheduleStore.save")
    }

    // MARK: - Acceptance #3: validation tooltips

    @Test("Compose fields surface AmplificationGuard rationale and compile errors via inline tooltips")
    func declaresValidationTooltips() {
        let src = Self.scheduleViewSource()
        #expect(!src.isEmpty, "ScheduleView.swift must be readable from the test")

        #expect(src.contains("cadenceValidationTooltip"),
                "compose fields must derive an inline validation tooltip")
        // The tooltip must combine the compile/parse error and the
        // AmplificationGuard rationale.
        #expect(src.contains("proseError") && src.contains("Amplification risk"),
                "the validation tooltip must surface both compile errors and the amplification rationale")
        #expect(src.contains(".help(cadenceValidationTooltip"),
                "the cadence field must attach the validation tooltip via .help()")
    }

    // MARK: - Regression: a-1 create-form + list/toggle/delete preserved

    @Test("a-1 compose surface and existing list/toggle/delete behavior are preserved")
    func a1AndExistingBehaviorPreserved() {
        let src = Self.scheduleViewSource()
        #expect(!src.isEmpty, "ScheduleView.swift must be readable from the test")

        // a-1 compose surface intact.
        #expect(src.contains("enum ComposeMode"),
                "a-1 ComposeMode enum must still exist")
        #expect(src.contains("amplificationBanner"),
                "a-1 amplification verdict banner must still exist")
        #expect(src.contains("nextFiresPreview") && src.contains("CronPreview.nextFires"),
                "a-1 next-fires preview must still exist")
        #expect(src.contains("var canCreate") && src.contains("disabled(!canCreate)"),
                "a-1 confirm-gating (canCreate) must still gate Create")
        #expect(src.contains("CompositeProseCadenceCompiler"),
                "a-1 prose compiler wiring must still exist")

        // Existing list / toggle / delete intact.
        #expect(src.contains("private var taskListView"),
                "task list view must still exist")
        #expect(src.contains("func toggleTask"),
                "enable/disable toggle action must still exist")
        #expect(src.contains("func removeTask"),
                "delete action must still exist")
        #expect(src.contains("ScheduleStore.remove"),
                "delete persistence via ScheduleStore.remove must be unchanged")
        #expect(src.contains("ScheduleStore.list"),
                "task loading via ScheduleStore.list must be unchanged")
    }
}
