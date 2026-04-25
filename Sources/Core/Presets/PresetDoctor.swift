import Foundation

/// Doctor integration for scheduled presets.
///
/// Walks every `ScheduledTask` currently stored under
/// `~/.senkani/schedules/`, matches each by name against
/// `PresetCatalog.shipped`, and surfaces missing prerequisites via
/// `PresetPrerequisiteCheck`. Used by `senkani doctor` to surface
/// "you installed `autoresearch` but `guard-research` isn't live yet"
/// at diagnosis time.
///
/// Kept as a separate type (not folded into DoctorCommand) so it is
/// unit-testable without spawning a Process — tests can pass a stub
/// task list and assert the walker's output.
public enum PresetDoctor {

    public struct Report: Sendable, Equatable {
        /// Task-name → list of prerequisite warnings. Only installed
        /// tasks whose name matches a shipped preset appear here;
        /// ad-hoc `senkani schedule create` tasks are skipped since
        /// they have no prerequisites declared.
        public let byTask: [String: [PresetPrerequisiteCheck.CheckResult.Warning]]

        /// True when every checked task is fully ready (no warnings).
        public var clean: Bool {
            byTask.values.allSatisfy { $0.isEmpty }
        }
    }

    /// Check all installed tasks against shipped preset prerequisites.
    /// Uses the live `ScheduleStore.list()` + `PresetCatalog` by default.
    public static func check() -> Report {
        check(tasks: ScheduleStore.list(), presets: PresetCatalog.shipped)
    }

    /// Pure-function variant — test hook. Callers pass the exact task +
    /// preset sets the report should be built from.
    public static func check(
        tasks: [ScheduledTask],
        presets: [ScheduledPreset]
    ) -> Report {
        let presetsByName = Dictionary(uniqueKeysWithValues: presets.map { ($0.name, $0) })
        var out: [String: [PresetPrerequisiteCheck.CheckResult.Warning]] = [:]
        for task in tasks {
            guard let preset = presetsByName[task.name] else { continue }
            let result = PresetPrerequisiteCheck.check(preset)
            out[task.name] = result.warnings
        }
        return Report(byTask: out)
    }

    /// One-line summary for CLI printing. Returns `nil` when the report
    /// is clean so callers print nothing.
    public static func summaryMessage(_ report: Report) -> String? {
        let dirty = report.byTask.filter { !$1.isEmpty }
        guard !dirty.isEmpty else { return nil }
        let names = dirty.keys.sorted().map { "`\($0)`" }.joined(separator: ", ")
        return "Schedule presets with missing prerequisites: \(names). Run `senkani schedule preset list` for detail."
    }
}
