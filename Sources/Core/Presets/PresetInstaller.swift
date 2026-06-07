import Foundation

/// Shared installer for `ScheduledTask`s. Writes the task JSON via
/// `ScheduleStore.save`, generates the launchd plist, and (in
/// production mode) runs `launchctl load`. Used by both
/// `senkani schedule create` (the low-level surface) and
/// `senkani schedule preset install` so the two code paths can't
/// drift.
///
/// The plist generation used to live as a private method on
/// `Schedule.Create`; extracting it here lets the preset install path
/// produce byte-identical plists without duplicating 80 LOC.
public enum PresetInstaller {

    /// Result of building + writing the plist, independent of the
    /// launchctl-load step. Tests can invoke `install` with
    /// `loadWithLaunchctl: false` and assert the XML on disk.
    public struct InstallResult: Sendable {
        public let task: ScheduledTask
        public let plistPath: String
        public let plistXML: String
        public let launchctlLoaded: Bool
    }

    public enum InstallError: Error, Equatable {
        case invalidCronPattern(String)
        case writeFailed(String)
        /// `launchctl load` returned a non-zero exit (after one retry). On an
        /// edit-in-place this is the DISARMED case: the prior job was already
        /// unloaded and the new plist is on disk, but the (re)load failed — so
        /// the schedule will NOT fire until reloaded. Surfaced (instead of the
        /// old stderr-only warning) so the GUI/CLI tell the operator the
        /// schedule is not armed rather than silently leaving it down.
        case loadFailed(plistPath: String)
    }

    /// Write the `ScheduledTask` JSON + generate the launchd plist +
    /// (if `loadWithLaunchctl`) run `launchctl load`. Callers:
    /// - `schedule create` → `loadWithLaunchctl: true`
    /// - `schedule preset install` → `loadWithLaunchctl: true`
    /// - tests → `loadWithLaunchctl: false`
    ///
    /// `binaryPath` defaults to the running executable's path; tests
    /// pass a stable placeholder so the generated XML is deterministic.
    public static func install(
        task: ScheduledTask,
        binaryPath: String? = nil,
        loadWithLaunchctl: Bool = true
    ) throws -> InstallResult {
        let resolvedBinary = binaryPath
            ?? ProcessInfo.processInfo.arguments.first
            ?? "/usr/local/bin/senkani"

        // Validate the cron up front so we fail before touching disk.
        guard let intervals = CronToLaunchd.convert(task.cronPattern) else {
            throw InstallError.invalidCronPattern(task.cronPattern)
        }

        // 1. Save the task JSON
        do {
            try ScheduleStore.save(task)
        } catch {
            throw InstallError.writeFailed("ScheduleStore.save failed: \(error)")
        }

        // 2. Ensure logs dir exists
        let fm = FileManager.default
        let logsDir = ScheduleStore.logsDir
        if !fm.fileExists(atPath: logsDir) {
            try? fm.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        }

        // 3. Build plist XML
        let xml = renderPlistXML(task: task, binaryPath: resolvedBinary, intervals: intervals)

        // 4. Write plist
        let label = ScheduleStore.plistLabel(for: task.name)
        let launchAgentsDir = ScheduleStore.launchAgentsDir
        let plistPath = launchAgentsDir + "/\(label).plist"
        if !fm.fileExists(atPath: launchAgentsDir) {
            try? fm.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)
        }

        // Transactional ordering (edit-in-place hardening): write the NEW
        // plist BEFORE unloading the prior job. `atomically: true` writes to a
        // temp file and renames over the destination, so a thrown write leaves
        // the prior plist — and thus the live launchd job — fully intact. The
        // old ordering (unload → write) left an inconsistent triple
        // (JSON=new, plist=old, job=DOWN) with no rollback if the write threw.
        let priorPlistExisted = fm.fileExists(atPath: plistPath)

        do {
            try xml.write(toFile: plistPath, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.writeFailed("plist write failed: \(error)")
        }

        // Re-arm: with the new plist already on disk, unload the prior job then
        // (re)load below. Both cadences carry the SAME launchd Label, so
        // unloading the just-written file unloads the live job, and the reload
        // arms the new cadence. A fresh install (no prior plist) skips the
        // unload, leaving the create path unchanged.
        if loadWithLaunchctl && priorPlistExisted {
            ScheduleStore.runLaunchctl(verb: "unload", plistPath: plistPath)
        }

        // 5. Optionally run launchctl load (re-arming the new cadence).
        //
        // Disarm hardening: on an edit-in-place the prior job was unloaded
        // just above, so a failed `load` here would leave the schedule
        // DISARMED (new plist on disk, job DOWN). The old code only logged a
        // stderr warning and returned `launchctlLoaded: false`, so the
        // operator was never told the schedule wasn't armed. Now we retry the
        // load ONCE (covers a transient launchctl hiccup) and, if it still
        // fails, throw a typed `InstallError.loadFailed` — which both the GUI
        // edit path (`catch let error as InstallError`) and the CLI
        // `schedule create` paths surface to the operator. A successful load
        // (fresh install or edit) behaves exactly as before: no error.
        var loaded = false
        if loadWithLaunchctl {
            loaded = ScheduleStore.runLaunchctl(verb: "load", plistPath: plistPath)
            if !loaded {
                // One retry before surfacing — guards against a transient
                // launchctl failure without masking a genuine disarm.
                loaded = ScheduleStore.runLaunchctl(verb: "load", plistPath: plistPath)
            }
            if !loaded {
                throw InstallError.loadFailed(plistPath: plistPath)
            }
        }

        return InstallResult(
            task: task,
            plistPath: plistPath,
            plistXML: xml,
            launchctlLoaded: loaded
        )
    }

    /// Idempotently re-arm the live launchd job for an already-installed
    /// `task` — unload the existing label (if loaded) then (re)load the
    /// regenerated plist so an edited cadence fires WITHOUT a logout/login
    /// or manual `launchctl`. Thin alias over `install`, which already
    /// performs the unload-then-load when a prior plist is present; exposed
    /// as an explicit verb the edit path can call to express intent.
    @discardableResult
    public static func reload(
        task: ScheduledTask,
        binaryPath: String? = nil,
        loadWithLaunchctl: Bool = true
    ) throws -> InstallResult {
        try install(task: task, binaryPath: binaryPath, loadWithLaunchctl: loadWithLaunchctl)
    }

    /// Pure plist XML builder — no side effects. Exposed so tests can
    /// assert the XML shape for a given (task, binaryPath) pair without
    /// writing to disk.
    public static func renderPlistXML(
        task: ScheduledTask,
        binaryPath: String,
        intervals: [[String: Int]]
    ) -> String {
        let label = ScheduleStore.plistLabel(for: task.name)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>schedule</string>
                <string>run</string>
                <string>--name</string>
                <string>\(task.name)</string>
            </array>
            <key>StartCalendarInterval</key>

        """

        if intervals.count == 1 {
            xml += "    <dict>\n"
            for (key, value) in intervals[0].sorted(by: { $0.key < $1.key }) {
                xml += "        <key>\(key)</key>\n"
                xml += "        <integer>\(value)</integer>\n"
            }
            xml += "    </dict>\n"
        } else {
            xml += "    <array>\n"
            for interval in intervals {
                xml += "        <dict>\n"
                for (key, value) in interval.sorted(by: { $0.key < $1.key }) {
                    xml += "            <key>\(key)</key>\n"
                    xml += "            <integer>\(value)</integer>\n"
                }
                xml += "        </dict>\n"
            }
            xml += "    </array>\n"
        }

        xml += """
            <key>StandardOutPath</key>
            <string>\(home)/.senkani/logs/\(task.name).log</string>
            <key>StandardErrorPath</key>
            <string>\(home)/.senkani/logs/\(task.name).err</string>
        </dict>
        </plist>

        """
        return xml
    }
}
