import Testing
import Foundation
@testable import Core

/// Behavioral coverage for the schedule edit-lifecycle launchd re-arm gaps
/// (group `schedule-lifecycle`):
///
/// - `schedule-edit-in-place-launchd-rearm-2026-05-31` — editing a cron/prose
///   schedule's cadence must UNLOAD-then-(re)LOAD the live launchd job so the
///   edited cadence actually fires; the create path (no prior plist) just
///   loads, with no spurious unload.
/// - `schedule-edit-mode-switch-stale-plist-2026-05-31` — editing a cron/prose
///   schedule DOWN to counter mode must unload+remove the prior plist so the
///   old job can't keep firing (ghost double-fire).
/// - `schedule-movetasks-overloads-createdat-2026-05-31` — drag-reorder must
///   persist via a dedicated `sortIndex`, preserving `createdAt`, with graceful
///   migration of legacy (sortIndex-less) rows.
///
/// These are FILE-SYSTEM + recorded-`launchctl` behavioral tests (plist
/// presence/absence + the seam's `unload`/`load` invocation order) under the
/// `ScheduleStore.withTestDirs` temp-dir + `withLaunchctlRecorder` seams — not
/// source-scan guards — so the regression class is caught by CI rather than
/// manual real-machine observation.
@Suite("Schedule edit-lifecycle launchd re-arm + sortIndex")
struct ScheduleLifecycleLaunchdTests {

    /// Run `body` inside a fresh temp schedules+LaunchAgents dir pair, with a
    /// `launchctl` recorder installed. Cleans up the temp dirs afterward.
    private func withTempStore(
        _ body: (_ base: String, _ launch: String, _ rec: ScheduleStore.LaunchctlRecorder) throws -> Void
    ) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-schedule-lifecycle-\(UUID().uuidString)")
        let base = tmp.appendingPathComponent("schedules").path
        let launch = tmp.appendingPathComponent("LaunchAgents").path
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: launch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rec = ScheduleStore.LaunchctlRecorder()
        try ScheduleStore.withTestDirs(base: base, launchAgents: launch) {
            try ScheduleStore.withLaunchctlRecorder(rec) {
                try body(base, launch, rec)
            }
        }
    }

    private func cronTask(_ name: String, cron: String, prose: String? = nil) -> ScheduledTask {
        ScheduledTask(
            name: name, cronPattern: cron, command: "senkani digest",
            budgetLimitCents: nil, enabled: true,
            proseCadence: prose, compiledCadence: prose == nil ? nil : cron
        )
    }

    // MARK: - edit-in-place re-arm

    @Test("Fresh install loads only (no spurious unload) — create path unchanged")
    func freshInstallLoadsOnly() throws {
        try withTempStore { _, launch, rec in
            let task = cronTask("rearm-create", cron: "0 9 * * *")
            _ = try PresetInstaller.install(
                task: task, binaryPath: "/opt/senkani/senkani", loadWithLaunchctl: true
            )
            // No prior plist → exactly one `load`, no `unload`.
            #expect(rec.verbs == ["load"],
                    "fresh install must issue a single load with no spurious unload")
            #expect(FileManager.default.fileExists(
                atPath: launch + "/com.senkani.schedule.rearm-create.plist"))
        }
    }

    @Test("Editing an existing cron/prose schedule re-arms the live job: unload THEN load")
    func editInPlaceUnloadsThenLoads() throws {
        try withTempStore { _, launch, rec in
            // 1. Install the original cadence (records one `load`).
            let original = cronTask("rearm-edit", cron: "0 9 * * *")
            _ = try PresetInstaller.install(
                task: original, binaryPath: "/opt/senkani/senkani", loadWithLaunchctl: true)

            // 2. Edit the cadence and re-install (the GUI edit path / reload).
            let edited = cronTask("rearm-edit", cron: "0 18 * * *")
            _ = try PresetInstaller.reload(
                task: edited, binaryPath: "/opt/senkani/senkani", loadWithLaunchctl: true)

            // The edit must unload the already-loaded label BEFORE (re)loading
            // — otherwise `load` is a no-op and the OLD cadence keeps firing.
            #expect(rec.verbs == ["load", "unload", "load"],
                    "edit-in-place must unload-then-load to re-arm the live job; got \(rec.verbs)")

            // The plist on disk carries the NEW cadence (18:00, Hour 18).
            let xml = try String(
                contentsOfFile: launch + "/com.senkani.schedule.rearm-edit.plist", encoding: .utf8)
            #expect(xml.contains("<integer>18</integer>"),
                    "re-armed plist must carry the edited cadence")
        }
    }

    @Test("install with loadWithLaunchctl:false performs no launchctl calls (test/render mode)")
    func renderModeIssuesNoLaunchctl() throws {
        try withTempStore { _, _, rec in
            let task = cronTask("rearm-render", cron: "0 9 * * *")
            _ = try PresetInstaller.install(
                task: task, binaryPath: "/opt/senkani/senkani", loadWithLaunchctl: false)
            #expect(rec.verbs.isEmpty,
                    "loadWithLaunchctl:false must not touch launchctl")
        }
    }

    // MARK: - mode-switch teardown (cron/prose -> counter)

    @Test("removePlist unloads + deletes a loaded plist, leaves JSON intact")
    func removePlistUnloadsAndDeletesPlistOnly() throws {
        try withTempStore { base, launch, rec in
            let task = cronTask("modeswitch", cron: "0 9 * * *")
            _ = try PresetInstaller.install(
                task: task, binaryPath: "/opt/senkani/senkani", loadWithLaunchctl: true)
            let plistPath = launch + "/com.senkani.schedule.modeswitch.plist"
            #expect(FileManager.default.fileExists(atPath: plistPath))

            let removed = ScheduleStore.removePlist("modeswitch")
            #expect(removed, "removePlist must report it removed an existing plist")
            // The prior plist must be unloaded then deleted...
            #expect(rec.verbs == ["load", "unload"],
                    "mode-switch teardown must unload the prior job; got \(rec.verbs)")
            #expect(!FileManager.default.fileExists(atPath: plistPath),
                    "prior plist file must be removed so no ghost job remains")
            // ...but the JSON config must remain (the row still exists, now as
            // a counter cadence after the caller re-saves it).
            #expect(FileManager.default.fileExists(atPath: base + "/modeswitch.json"),
                    "removePlist must NOT delete the JSON config")
        }
    }

    @Test("removePlist is a no-op (no unload) when no plist exists")
    func removePlistNoopWhenAbsent() throws {
        try withTempStore { _, _, rec in
            let removed = ScheduleStore.removePlist("never-installed")
            #expect(!removed)
            #expect(rec.verbs.isEmpty, "no plist → no launchctl unload")
        }
    }

    @Test("Counter-mode edit teardown: prior cron plist gone, only counter JSON remains (no double-fire)")
    func modeSwitchToCounterRemovesPriorPlist() throws {
        try withTempStore { base, launch, _ in
            // 1. A cron schedule with a live plist.
            let cron = cronTask("switcher", cron: "0 9 * * *")
            _ = try PresetInstaller.install(
                task: cron, binaryPath: "/opt/senkani/senkani", loadWithLaunchctl: true)
            let plistPath = launch + "/com.senkani.schedule.switcher.plist"
            #expect(FileManager.default.fileExists(atPath: plistPath))

            // 2. Edit DOWN to counter mode — the edit lifecycle removes the
            //    prior plist (what ScheduleView.createSchedule now does) then
            //    saves the counter JSON (sentinel cron, no plist).
            _ = ScheduleStore.removePlist("switcher")
            let counter = ScheduledTask(
                name: "switcher", cronPattern: "COUNTER:tool_calls:10",
                command: "senkani digest", enabled: true,
                eventCounterCadence: "every 10 tool_calls")
            try ScheduleStore.save(counter)

            // No ghost cron plist; the row is now a single counter cadence.
            #expect(!FileManager.default.fileExists(atPath: plistPath),
                    "no stale cron plist may survive a switch to counter mode")
            let loaded = ScheduleStore.load("switcher")
            #expect(loaded?.eventCounterCadence == "every 10 tool_calls")
            #expect(FileManager.default.fileExists(atPath: base + "/switcher.json"))
        }
    }

    // MARK: - sortIndex drag-reorder (createdAt preserved)

    @Test("Drag-reorder persists via sortIndex and preserves createdAt")
    func reorderUsesSortIndexPreservesCreatedAt() throws {
        try withTempStore { _, _, _ in
            // Three rows with DISTINCT, real creation timestamps.
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let a = ScheduledTask(name: "a", cronPattern: "0 9 * * *", command: "c",
                                  createdAt: t0)
            let b = ScheduledTask(name: "b", cronPattern: "0 9 * * *", command: "c",
                                  createdAt: t0.addingTimeInterval(100))
            let c = ScheduledTask(name: "c", cronPattern: "0 9 * * *", command: "c",
                                  createdAt: t0.addingTimeInterval(200))
            for t in [a, b, c] { try ScheduleStore.save(t) }

            // Initial order is by createdAt: a, b, c.
            #expect(ScheduleStore.list().map(\.name) == ["a", "b", "c"])

            // Reorder to c, a, b by stamping a dense sortIndex (what
            // ScheduleView.moveTasks now does) WITHOUT touching createdAt.
            for (i, name) in ["c", "a", "b"].enumerated() {
                var t = ScheduleStore.load(name)!
                t.sortIndex = i
                try ScheduleStore.save(t)
            }

            let after = ScheduleStore.list()
            #expect(after.map(\.name) == ["c", "a", "b"],
                    "list() must honor sortIndex order")
            // createdAt must be the GENUINE timestamps, untouched.
            let byName = Dictionary(uniqueKeysWithValues: after.map { ($0.name, $0) })
            #expect(byName["a"]?.createdAt == t0)
            #expect(byName["b"]?.createdAt == t0.addingTimeInterval(100))
            #expect(byName["c"]?.createdAt == t0.addingTimeInterval(200))
        }
    }

    @Test("list() migrates legacy rows: sortIndex-less rows fall back to createdAt and sort after ordered rows")
    func legacyRowsMigrateGracefully() throws {
        try withTempStore { _, _, _ in
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            // legacy1/legacy2 have NO sortIndex; ordered has sortIndex 0.
            let legacy1 = ScheduledTask(name: "legacy1", cronPattern: "0 9 * * *",
                                        command: "c", createdAt: t0.addingTimeInterval(50))
            let legacy2 = ScheduledTask(name: "legacy2", cronPattern: "0 9 * * *",
                                        command: "c", createdAt: t0.addingTimeInterval(10))
            let ordered = ScheduledTask(name: "ordered", cronPattern: "0 9 * * *",
                                        command: "c", createdAt: t0.addingTimeInterval(999),
                                        sortIndex: 0)
            for t in [legacy1, legacy2, ordered] { try ScheduleStore.save(t) }

            // Explicitly-ordered row first; legacy rows after, in createdAt
            // order (legacy2 @ +10 before legacy1 @ +50).
            #expect(ScheduleStore.list().map(\.name) == ["ordered", "legacy2", "legacy1"])
        }
    }

    @Test("With NO sortIndex anywhere, list() reproduces the legacy pure-createdAt order")
    func allLegacyReproducesCreatedAtOrder() throws {
        try withTempStore { _, _, _ in
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let x = ScheduledTask(name: "x", cronPattern: "0 9 * * *", command: "c",
                                  createdAt: t0.addingTimeInterval(300))
            let y = ScheduledTask(name: "y", cronPattern: "0 9 * * *", command: "c",
                                  createdAt: t0.addingTimeInterval(100))
            let z = ScheduledTask(name: "z", cronPattern: "0 9 * * *", command: "c",
                                  createdAt: t0.addingTimeInterval(200))
            for t in [x, y, z] { try ScheduleStore.save(t) }
            #expect(ScheduleStore.list().map(\.name) == ["y", "z", "x"])
        }
    }

    @Test("sortIndex round-trips through JSON; legacy JSON without the key decodes as nil")
    func sortIndexCodableMigration() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let withIndex = ScheduledTask(name: "wi", cronPattern: "0 9 * * *", command: "c",
                                      sortIndex: 7)
        let round = try decoder.decode(ScheduledTask.self, from: try encoder.encode(withIndex))
        #expect(round.sortIndex == 7)

        // Legacy JSON (no sortIndex key) must decode with sortIndex == nil.
        let legacyJSON = """
        {"name":"old","cronPattern":"0 9 * * *","command":"c","enabled":true,"createdAt":"2024-01-01T00:00:00Z","worktree":false}
        """
        let legacy = try decoder.decode(ScheduledTask.self, from: Data(legacyJSON.utf8))
        #expect(legacy.sortIndex == nil)
        #expect(legacy.name == "old")
    }

    // MARK: - transactional plist write + isLaunchdBacked edge

    @Test("Transactional edit: a thrown plist write does NOT unload the live job")
    func transactionalWriteFailureKeepsPriorJobLoaded() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-tx-\(UUID().uuidString)")
        let base = tmp.appendingPathComponent("schedules").path
        let launch = tmp.appendingPathComponent("LaunchAgents").path
        try FileManager.default.createDirectory(atPath: launch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let rec = ScheduleStore.LaunchctlRecorder()
        let task = ScheduledTask(name: "txtest", cronPattern: "0 9 * * *", command: "echo hi")
        // Block the write: a directory where the plist file would go. fileExists
        // → true (so priorPlistExisted is true) but `write` over a directory
        // throws, exercising the failure branch.
        let plistPath = launch + "/\(ScheduleStore.plistLabel(for: task.name)).plist"
        try FileManager.default.createDirectory(atPath: plistPath, withIntermediateDirectories: true)
        try ScheduleStore.withTestDirs(base: base, launchAgents: launch) {
            try ScheduleStore.withLaunchctlRecorder(rec) {
                #expect(throws: PresetInstaller.InstallError.self) {
                    _ = try PresetInstaller.install(
                        task: task, binaryPath: "/usr/local/bin/senkani", loadWithLaunchctl: true)
                }
            }
        }
        #expect(rec.verbs.isEmpty,
                "a failed plist write must not unload the live job; verbs=\(rec.verbs)")
    }

    @Test("removePlist operates on the path plistLabel(for:) produces")
    func removePlistUsesPlistLabelPath() throws {
        try withTempStore { _, launch, _ in
            let task = cronTask("labelparity", cron: "0 9 * * *")
            // Install the plist WITHOUT touching launchctl (render mode) so the
            // file lands at exactly plistLabel(for:)'s path.
            _ = try PresetInstaller.install(
                task: task, binaryPath: "/opt/senkani/senkani", loadWithLaunchctl: false)
            let expectedPath = launch + "/\(ScheduleStore.plistLabel(for: "labelparity")).plist"
            #expect(FileManager.default.fileExists(atPath: expectedPath))

            let removed = ScheduleStore.removePlist("labelparity")
            #expect(removed, "removePlist must report it removed the existing plist")
            #expect(!FileManager.default.fileExists(atPath: expectedPath),
                    "removePlist must delete the file at plistLabel(for:)'s path")
        }
    }

    @Test("isLaunchdBacked: nil cadence is launchd-backed; empty-string and populated counter are not")
    func isLaunchdBackedEmptyStringEdge() {
        #expect(ScheduledTask(name: "a", cronPattern: "0 9 * * *", command: "c")
            .isLaunchdBacked == true)
        #expect(ScheduledTask(name: "b", cronPattern: "@counter", command: "c",
                              eventCounterCadence: "").isLaunchdBacked == false)
        #expect(ScheduledTask(name: "c", cronPattern: "@counter", command: "c",
                              eventCounterCadence: "5").isLaunchdBacked == false)
    }
}
